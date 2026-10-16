import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 书城筛选栏滚动收缩：滚动多远后完整栏收缩成一行（对齐 demo 稿的 `RANGE = 60`）。
private let exploreFilterCollapseRange: CGFloat = 60

/// 书目列表的滚动偏移：首行零高标记在 `exploreScroll` 坐标空间里的 `minY`（顶部 0、下滑为负）。
private struct ExploreScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 书城 —— 分类胶囊栏 + 分类书目分页（U5-3）。
///
/// ## 与 Reducer 的分工
/// 本文件**只管展示和用户交互**：固定分类目录、书目联网、分页游标、末页判定全在 `ExploreFeature`
/// （见 `Packages/NovelCore/Sources/NovelCore/Explore/ExploreFeature.swift`）。
///
/// ## 为什么用 `WithViewStore` 而不是 `store.state`
/// 与书架页 / 搜索页一致：`store.state` 要求 `State: ObservableState`（`@ObservableState` 宏），
/// 而宏在 CI 的 xcodebuild 下跑不起来（见 `CLAUDE.md` §1）。`WithViewStore` 不依赖任何宏。
///
/// ## 详情页接线为什么和搜索页逐行对齐
/// 书目行点进去就是 `BookDetailView`，详情页里的「加入书架 / 移出书架」必须能回写书架状态，
/// 所以本页照 `SearchView` 接同样的 `onBookAdded` / `onBookRemoved` 回调，
/// 由 `RootView` 转交给 `bookshelfStore` —— 不自创第二套回调协议。
/// ⚠️ 唯一少掉的是 `SearchView` 里那两行 `viewStore.send(.addSucceeded / .removedFromShelf)`：
/// `ExploreFeature.Action` 的对外用例只有 `task / categorySelected / loadMore / retry`，
/// 没有「已加入集合」这层状态，所以这里只转发回调，不能凭空发不存在的 action。
public struct ExploreView: View {
    let store: StoreOf<ExploreFeature>
    let downloadStore: StoreOf<DownloadFeature>
    let onBookAdded: (ShelfRow) -> Void
    let onBookRemoved: (String) -> Void

    /// 详情页 push 目标。与书架页 / 搜索页一致用**显式 push** 而不是 `NavigationLink`：
    /// `List` 行里的 `NavigationLink` 会把整行接管成跳转目标（B0-5「看不到按钮」的成因）。
    @State private var detailBook: Book?
    @State private var isShowingDetail = false

    /// 筛选栏滚动收缩进度（0 = 完整三行，1 = 收缩成一行），由书目列表滚动偏移驱动。
    @State private var filterCollapseProgress: Double = 0
    /// 点收缩态胶囊后进入「手动展开」：进度改由滚动增量驱动，直到再次收缩到底。
    @State private var isFilterManualExpanded = false
    /// 上一次滚动偏移，用于计算滚动增量。
    @State private var lastFilterScrollOffset: CGFloat = 0

    init(
        store: StoreOf<ExploreFeature>,
        downloadStore: StoreOf<DownloadFeature>,
        onBookAdded: @escaping (ShelfRow) -> Void = { _ in },
        onBookRemoved: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.downloadStore = downloadStore
        self.onBookAdded = onBookAdded
        self.onBookRemoved = onBookRemoved
    }

    public var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 0) {
                    categoryBar(viewStore, collapseProgress: filterCollapseProgress) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isFilterManualExpanded = true
                            filterCollapseProgress = 0
                        }
                    }

                    // 自撑满：内容区只剩一个 `ContentUnavailableView` 时不能跟着它缩水，
                    // 否则分类栏会被整体居中（同 `BookshelfView` 的 `body` 对内容区 `ZStack` 的自撑满写法与理由）。
                    content(viewStore)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // 切分类 / 首屏加载会让内容区离开 `bookList`（List 消失、滚动偏移归零），
                // 此时把收缩进度归零，避免残留的收缩态盖在加载态上。
                .onChange(of: viewStore.isLoading) { _, isLoading in
                    if isLoading {
                        filterCollapseProgress = 0
                        isFilterManualExpanded = false
                    }
                }
                // U1-1：页面底 = 浅色分组灰（`AppTheme.Surface.page`），卡面 = 白（`AppTheme.Surface.card`）。
                .background(AppTheme.Surface.page)
                .navigationTitle("书城")
                // 底栏可见性的**唯一所有者**就是每个 tab 根视图（同 `BookshelfView` / `SearchView`），
                // 由状态驱动。push 详情期间根的状态是 `.hidden` ⇒ 详情页没有底栏；pop 回根时
                // 翻回 `.visible` ⇒ 底栏可靠恢复。详情页自己不再声明底栏，所以「根视图声明胜出」
                // 与「最上层声明胜出」两种偏好解析模型下行为一致。
                .toolbar(isShowingDetail ? .hidden : .visible, for: .tabBar)
                // 底栏**背景**同样由根视图声明为「始终可见」：iOS 15+ 的底栏有 scroll-edge 外观，
                // 内容没滚动（空态 / 列表不够长）时背景本来就是透明的 —— 真机「底栏偶尔变透明」就是它。
                // 与上面的可见性同一层声明；阅读页整条底栏是 `.hidden`，专注模式不受影响。
                .toolbarBackground(.visible, for: .tabBar)
                // 每次出现都发 `.task`：reducer 内部对「已在加载中」做了去重，
                // 所以 pop 回来重复触发不会打两次首页（见 `ExploreFeature` 的 `.task` 分支）。
                .onAppear { viewStore.send(.task) }
                .navigationDestination(isPresented: $isShowingDetail) {
                    if let book = detailBook {
                        BookDetailView(
                            book: book,
                            downloadStore: downloadStore,
                            // 详情页加入 / 移出书架后，书架 tab 立刻跟上，
                            // 不依赖「切回书架时重拉一次」这种时序假设。
                            onAddedToShelf: { row in
                                onBookAdded(row)
                            },
                            onRemovedFromShelf: { bookPath in
                                onBookRemoved(bookPath)
                            }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - 内容区

private extension ExploreView {
    /// 加载中 / 失败 / 未选分类 / 分类下无书 / 书目列表 五态切换。
    ///
    /// 加载态排在最前（同 `SearchView` 的 `content(_:)` 的顺序）：切分类时旧书目要立刻让位，
    /// 否则上一个分类的列表原样留着，看起来像没点中。
    /// 它同时兜住「还没有分类、也还没有失败」的那一帧：`.task` 是 `onAppear` 之后才发的，
    /// 这一帧若判成失败，进页面会先闪一下「加载失败」；固定分类由 `.task` 同步填入，
    /// 所以「分类为空且无错误」只可能是首次发起请求前的短暂状态。
    ///
    /// 🔴 这里的整页失败态**只**由 `errorMessage`（分类 / 首屏失败）触发：
    /// 「加载更多」失败是局部失败，走 `moreErrorMessage`，只在底部分页行上就地提示 ——
    /// 已经加载好的书目不许被它顶掉（见 `bookList`）。
    @ViewBuilder
    private func content(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        let isPreparing = viewStore.categories.isEmpty && viewStore.errorMessage == nil
        if viewStore.isLoading || isPreparing {
            loadingView
        } else if let message = viewStore.errorMessage {
            failureView(message, viewStore: viewStore)
        } else if viewStore.selectedCategory == nil {
            selectCategoryView
        } else if viewStore.books.isEmpty {
            emptyBooksView
        } else {
            bookList(viewStore)
        }
    }

    private var loadingView: some View {
        ProgressView("加载中…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 失败态：标题回答「是什么」，`message` 回答「为什么」，按钮回答「怎么办」。
    /// `message` 是 reducer 组装好的中文文案（分类拉取失败 / 首页解析不出分类 / 书目加载失败）。
    private func failureView(
        _ message: String,
        viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        ContentUnavailableView {
            Label("书城加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            // HIG §9：系统 `.borderedProminent` 默认约 34pt 高，
            // `.controlSize(.large)` 把它抬到 44pt 命中区（同 `SearchView` 的 `errorView(_:viewStore:)`）。
            Button("重试") {
                viewStore.send(.retry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        // 铺底必须显式撑满：缺了它 CUV 只覆盖内容尺寸（同 `SearchView` 的 `errorView(_:viewStore:)` / `emptyView(title:message:)`）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectCategoryView: some View {
        ContentUnavailableView(
            "选择一个分类",
            systemImage: "square.grid.2x2",
            description: Text("点上方分类，挑一本想读的书。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyBooksView: some View {
        ContentUnavailableView(
            "该分类暂无书籍",
            systemImage: "books.vertical",
            description: Text("换一个分类看看，或稍后再来。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bookList(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        // 用 `ScrollView` + `LazyVStack` 而不是 `List`：去掉 `List` 的默认顶部内边距（修「卡片太靠下」）。
        // 滚动偏移由 LazyVStack 的 `.background(GeometryReader)` 上报（见下），
        // 零高标记行在 LazyVStack 里会被懒加载吞掉、坐标空间解析不出（minY 恒 0/NaN）。
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(ExploreDisplayRow.rows(
                    books: viewStore.books,
                    pageStarts: viewStore.pageStarts
                )) { row in
                    if let page = row.pageLabel {
                        ExplorePageLabelRow(page: page)
                    }

                    ExploreBookRow(book: row.book) {
                        detailBook = row.book
                        isShowingDetail = true
                    }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }

                if viewStore.moreErrorMessage != nil {
                    ExploreLoadMoreRetryRow {
                        viewStore.send(.retry)
                    }
                } else if viewStore.hasMore {
                    ExploreLoadMoreRow(isLoadingMore: viewStore.isLoadingMore) {
                        viewStore.send(.loadMore)
                    }
                } else {
                    ExploreEndOfResultsRow()
                }
            }
            // 滚动偏移用「整个内容作背景」的 GeometryReader 量 `minY`，比放进 LazyVStack 的零高标记更稳：
            // 零高标记行在 LazyVStack 里常被懒加载布局吞掉、坐标空间解析不出（minY 恒 0/NaN）。
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ExploreScrollOffsetKey.self,
                        value: proxy.frame(in: .named("exploreScroll")).minY
                    )
                }
            )
        }
        .coordinateSpace(name: "exploreScroll")
        .onPreferenceChange(ExploreScrollOffsetKey.self) { minY in
            handleFilterScroll(minY: minY)
        }
    }

    /// 由滚动偏移驱动收缩进度。普通态按绝对偏移成比例收缩；
    /// 「手动展开」态按滚动增量累加（对齐 demo 的 `collapseProgress += dy/RANGE`），
    /// 收缩到底后回到普通态。
    private func handleFilterScroll(minY: CGFloat) {
        guard minY.isFinite else { return }
        let offset = max(-minY, 0)
        let delta = offset - lastFilterScrollOffset
        lastFilterScrollOffset = offset
        if isFilterManualExpanded {
            filterCollapseProgress = min(
                max(filterCollapseProgress + Double(delta) / Double(exploreFilterCollapseRange), 0),
                1
            )
            if filterCollapseProgress >= 1 {
                isFilterManualExpanded = false
            }
        } else {
            filterCollapseProgress = min(
                max(Double(offset) / Double(exploreFilterCollapseRange), 0),
                1
            )
        }
    }
}

// MARK: - 书目行

/// 书城的书目行（与 `SearchView.swift` 的 `SearchResultRow` 卡面同形）：
/// 封面占位 + 书名 + 作者，整卡可点、按下有反馈、push 详情页。
/// 加书入口统一在详情页，由 `onAddedToShelf` 回写书架。
private struct ExploreBookRow: View {
    let book: Book
    let onOpen: () -> Void

    var body: some View {
        // 🔴 整卡跳详情用 `Button` + 外层显式 push，不用 `NavigationLink`。
        Button(action: onOpen) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                    .fill(AppTheme.Surface.inset)
                    .frame(width: 48, height: 64)
                    .overlay {
                        Image(systemName: "book.closed")
                            .foregroundStyle(.quaternary)
                    }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)

                    Text(book.author.isEmpty ? "未知作者" : book.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignTokens.Spacing.sm)
            .contentShape(Rectangle()) // 整张卡片可点
            // U1-1：卡面 = 白（`AppTheme.Surface.card`），压在页面的分组灰底上形成一级层次；
            // 圆角统一 `DesignTokens.Radius.sm` = 12。
            .background(
                AppTheme.Surface.card,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            )
        }
        // 强调层贴卡片自己的 12pt 圆角，避免按下瞬间在圆角外露出方角（U0-4）。
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))))
    }
}

// MARK: - Preview

#Preview {
    let category = ExploreCategory(title: "玄幻", urlTemplate: "/list/1/{{page}}.html")
    let store = Store(
        initialState: ExploreFeature.State(
            categories: [
                category,
                ExploreCategory(title: "都市", urlTemplate: "/list/2/{{page}}.html"),
            ],
            selectedCategory: category,
            books: [
                Book(path: "/49/49034/", title: "示例书"),
                Book(path: "/49/49035/", title: "另一本书"),
            ],
            hasMore: true
        )
    ) {
        ExploreFeature()
    }
    ExploreView(
        store: store,
        downloadStore: Store(initialState: DownloadFeature.State()) {
            DownloadFeature()
        }
    )
}
