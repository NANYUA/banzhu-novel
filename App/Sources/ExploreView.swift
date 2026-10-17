import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI
import UIKit

/// 书目列表的滚动偏移：内省承载 `ScrollView` 的 `UIScrollView`，用 KVO 监听 `contentOffset.y`。
///
/// 为什么不用 SwiftUI 的 `.coordinateSpace` + GeometryReader：
/// 对 `LazyVStack` 内容，命名坐标空间解析不可靠（`minY` 恒 0/NaN），
/// 两次尝试（零高标记行 / `.background(GeometryReader)`）都没让收缩在真机生效。
/// `contentOffset` 是 UIKit 滚动的真相源，KVO 一定拿得到。
private struct ExploreScrollOffsetReporter: UIViewRepresentable {
    let onOffsetChange: (CGFloat) -> Void

    func makeUIView(context _: Context) -> ExploreScrollOffsetReporterView {
        let view = ExploreScrollOffsetReporterView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onOffsetChange = onOffsetChange
        return view
    }

    func updateUIView(_ uiView: ExploreScrollOffsetReporterView, context _: Context) {
        uiView.onOffsetChange = onOffsetChange
    }
}

/// 承载滚动偏移上报的 `UIView`：进入窗口后沿 `superview` 链找到 `UIScrollView`，
/// KVO 监听 `contentOffset`。只挂一次（`didMoveToWindow` 里 `observation == nil` 守卫），
/// 离开窗口时释放观察、让旧 `UIScrollView` 可被回收。
private final class ExploreScrollOffsetReporterView: UIView {
    var onOffsetChange: ((CGFloat) -> Void)?
    private var observation: NSKeyValueObservation?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            observation = nil
            return
        }
        guard observation == nil else { return }
        var cursor: UIView? = self
        while let current = cursor {
            if let scrollView = current as? UIScrollView {
                observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                    self?.onOffsetChange?(scrollView.contentOffset.y)
                }
                // push 详情返回 / 切 tab 回来时 contentOffset 没变、KVO 不补发，
                // 手动上报一次当前偏移，避免吸顶栏进度停留在 0 而完整栏其实已经滚出。
                onOffsetChange?(scrollView.contentOffset.y)
                return
            }
            cursor = current.superview
        }
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

    /// 吸顶收缩栏出现进度：完整分组栏已随书目列表滚出可视区的比例（0 = 全在，1 = 完全滚出）。
    @State private var groupBarScrollOutProgress: Double = 0
    /// 完整分组栏的高度（在滚动内容里测量），用于把滚动偏移换算成滚出比例。
    @State private var groupBarHeight: CGFloat = 0
    /// 吸顶收缩栏自身高度，用于「从导航栏下缘下滑到位」的位移量。
    @State private var compactBarHeight: CGFloat = 0
    /// 吸顶栏是否「原地弹出」成完整分组栏：点三个选中胶囊后展开（列表停在原地不滚），
    /// 让用户改 状态/排序/分类；点外部遮罩或切换分类时收起。
    /// ⚠️ 不能 `private`：`ExploreView+CategoryBar.swift` 的 `compactBarOverlay` 需要从另一个文件设置它。
    @State var isGroupBarExpanded = false

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
                // 自撑满：内容区只剩一个 `ContentUnavailableView` 时不能跟着它缩水，
                // 否则分组栏会被整体居中（同 `BookshelfView` 的 `body` 对内容区 `ZStack` 的自撑满写法与理由）。
                // 完整分组栏在 `bookList` 的滚动内容里（跟随列表滚动），吸顶收缩栏以 overlay 挂在列表上。
                content(viewStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 切分类 / 首屏加载会让内容区离开 `bookList`（List 消失、滚动偏移归零），
                    // 此时把吸顶栏出现进度归零，避免残留的收缩态盖在加载态上。
                    .onChange(of: viewStore.isLoading) { _, isLoading in
                        if isLoading {
                            groupBarScrollOutProgress = 0
                            // 切分类会重载并回到列表顶部，原地展开的完整栏一并收起。
                            isGroupBarExpanded = false
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
        // 滚动偏移由 `ExploreScrollOffsetReporter` 内省 UIScrollView.contentOffset 上报（见下），
        // 不再用 SwiftUI 的命名坐标空间（对 LazyVStack 解析不可靠）。
        ScrollView {
            LazyVStack(spacing: 0) {
                // 完整分组栏放进滚动内容（不再固定在顶部）：上滑时书目卡片整体上移盖过分组栏，
                // 完整栏随内容滚出可视区（owner 口径「先盖住分组，再从三个已选值下方划走」）。
                // 滚出后由下面的吸顶收缩栏（overlay）接管。
                groupBarHeader(viewStore)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        guard height > 0 else { return }
                        groupBarHeight = height
                    }

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
            // 滚动偏移由内省的 UIScrollView.contentOffset 上报（真相源），见 `ExploreScrollOffsetReporter`。
            .background(
                ExploreScrollOffsetReporter { offsetY in
                    handleFilterScroll(offsetY: offsetY)
                }
            )
        }
        // 吸顶栏以 overlay 挂在列表顶部（不占布局空间，出现/消失不引起列表跳动）：
        // 完整栏滚出时显示收缩栏；点收缩栏胶囊原地弹出完整栏（`topBarOverlay` 两种形态）。
        .overlay(alignment: .top) {
            topBarOverlay(viewStore)
        }
    }

    /// 列表顶部的吸顶栏 overlay（两种形态）：
    /// - 未展开：吸顶收缩栏，完整栏滚出的后半程淡入 + 从导航栏下缘下滑，书目卡片从它下方划过；
    /// - 展开：原地弹出完整分组栏（列表停在原地），下面盖一层半透明遮罩，点遮罩收起。
    private func topBarOverlay(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        ZStack(alignment: .top) {
            if isGroupBarExpanded {
                // 半透明遮罩：挡住列表触摸（「列表停在原地不滚」），点它收起展开的完整栏。
                AppTheme.scrim
                    .onTapGesture { isGroupBarExpanded = false }
                    .transition(.opacity)
            }

            if isGroupBarExpanded {
                expandedGroupBarOverlay(viewStore)
                    .transition(.opacity)
            } else {
                compactBarOverlay(viewStore)
                    .opacity(compactBarOpacity)
                    .offset(y: -(1 - compactBarOpacity) * compactBarHeight)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        guard height > 0 else { return }
                        compactBarHeight = height
                    }
                    // 半透明以上才可交互；未出现时把触摸让给下面的列表。
                    .allowsHitTesting(compactBarOpacity >= 0.5)
                    // 裁掉下滑动画滑出到导航栏区域的部分（同旧收缩栏 ZStack + clipped 的写法）。
                    .clipped()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isGroupBarExpanded)
    }

    /// 吸顶收缩栏淡入比例：完整栏滚出 60% 后开始、完全滚出时到位
    /// （对齐 owner 口径的时序——先盖住分组栏，卡片再从「三个已选值」下方划走）。
    private var compactBarOpacity: Double {
        min(max((groupBarScrollOutProgress - 0.6) / 0.4, 0), 1)
    }

    /// 由滚动偏移换算完整分组栏的滚出比例（0 = 完整栏全在，1 = 完全滚出）。
    /// 完整栏已随内容滚动，这里不再有「原位收缩动画」，只驱动吸顶收缩栏的出现时机。
    private func handleFilterScroll(offsetY: CGFloat) {
        guard offsetY.isFinite else { return }
        let offset = max(offsetY, 0)
        groupBarScrollOutProgress = min(
            max(Double(offset) / Double(max(groupBarHeight, 1)), 0),
            1
        )
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
