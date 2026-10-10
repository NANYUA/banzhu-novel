import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 书城 —— 分类胶囊栏 + 分类书目分页（U5-3）。
///
/// ## 与 Reducer 的分工
/// 本文件**只管展示和用户交互**：分类的缓存 / 联网、分页游标、末页判定全在 `ExploreFeature`
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
                    categoryBar(viewStore)

                    // 自撑满：内容区只剩一个 `ContentUnavailableView` 时不能跟着它缩水，
                    // 否则分类栏会被整体居中（同 `BookshelfView.swift:75-76` 的写法与理由）。
                    content(viewStore)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // U1-1：页面底 = 浅色分组灰（`AppTheme.Surface.page`），卡面 = 白（`AppTheme.Surface.card`）。
                .background(AppTheme.Surface.page)
                .navigationTitle("书城")
                // 从详情页 pop 回本页后底栏必须回来：详情页有意
                // `.toolbar(.hidden, for: .tabBar)`，而那是被 push 视图上的偏好，
                // pop 回根视图后可能残留。全仓只有「隐藏」没有「恢复」，
                // 所以根视图在这里显式声明一次「底栏可见」
                // （照抄 `BookshelfView.swift:83-87` / `SearchView.swift:41-44`）。
                .toolbar(.visible, for: .tabBar)
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

// MARK: - 分类栏

private extension ExploreView {
    /// 分类栏：胶囊行 + 一条发丝分隔线。
    /// 与书架的 `groupBar`（`BookshelfView.swift:167-182`）同一套结构。
    func categoryBar(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        VStack(spacing: 0) {
            categoryChips(viewStore)

            // 分类栏与书目区之间的一条发丝分隔线（系统 `Divider()`，不自算 1px）。
            // 滚动书目时它固定不动，把「筛选」和「内容」两个区块分开。
            Divider()
        }
        .background(AppTheme.Surface.page)
    }

    /// 横向滚动的分类胶囊（照抄 `BookshelfView.swift:184-228` 的 `groupChips` 写法）。
    private func categoryChips(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(viewStore.categories) { category in
                    ExploreCategoryChip(
                        title: category.title,
                        isSelected: viewStore.selectedCategory == category
                    ) {
                        viewStore.send(.categorySelected(category))
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
    }
}

// MARK: - 内容区

private extension ExploreView {
    /// 加载中 / 失败 / 未选分类 / 分类下无书 / 书目列表 五态切换。
    ///
    /// 加载态排在最前（同 `SearchView.swift:107` 的顺序）：切分类时旧书目要立刻让位，
    /// 否则上一个分类的列表原样留着，看起来像没点中。
    /// 它同时兜住「还没有分类、也还没有失败」的那一帧：`.task` 是 `onAppear` 之后才发的，
    /// 这一帧若判成失败，进页面会先闪一下「加载失败」。reducer 对「首页解析不出分类」
    /// 一律置 `errorMessage`，所以「分类为空且无错误」只可能是还没请求完。
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
            // `.controlSize(.large)` 把它抬到 44pt 命中区（同 `SearchView.swift:137-141`）。
            Button("重试") {
                viewStore.send(.retry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        // 铺底必须显式撑满：缺了它 CUV 只覆盖内容尺寸（`SearchView.swift:143` / `:152` 同写法）。
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
        List {
            ForEach(viewStore.books) { book in
                ExploreBookRow(book: book) {
                    detailBook = book
                    isShowingDetail = true
                }
                .listRowInsets(
                    .init(
                        top: DesignTokens.Spacing.xs,
                        leading: DesignTokens.Spacing.md,
                        bottom: DesignTokens.Spacing.xs,
                        trailing: DesignTokens.Spacing.md
                    )
                )
                .listRowSeparator(.hidden)
                // 行背景清掉：卡面颜色由 `ExploreBookRow` 自己画（`AppTheme.Surface.card`），
                // 这里再铺一层 List 默认的 `systemBackground`（浅色纯白）会把卡片之间的
                // 间隙也涂白，卡片就与页面分不出层次了（同 `SearchView.swift:179-182`）。
                .listRowBackground(Color.clear)
            }

            if viewStore.hasMore {
                loadMoreRow(viewStore)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // 让 List 自己的滚动背景透出页面分组灰。
        .scrollContentBackground(.hidden)
    }

    /// 分页入口：`hasMore == true` 才出现；加载中显示进度并禁用，重复点不会拉出重复页。
    private func loadMoreRow(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if viewStore.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                viewStore.send(.loadMore)
            } label: {
                Text("加载更多")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(viewStore.isLoadingMore)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 分类胶囊

/// 与书架的 `GroupChip`（`BookshelfView.swift:423-449`）逐项对齐：同为 44pt 胶囊、
/// 同样的选中填充与按下反馈 —— 同类控件必须用同一种视觉语言。
private struct ExploreCategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.xs)
                // §9 触控目标：胶囊本身做到 44pt —— 强调层贴的就是它，所以不会出现「按下变胖」。
                .frame(minHeight: 44)
                // 未选中 = 白卡面 + 主色文字（U1-1 的「卡面 = 白」同样适用于分类栏里的贴片）；
                // 选中 = 品牌强调色填充。
                .background(
                    Capsule().fill(
                        isSelected ? AppTheme.accent : AppTheme.Surface.card
                    )
                )
                // ⚠️ 这里的 `Color.white` 与书架胶囊一致，是 owner **已裁定「保持现状」**的一项：
                // 深色下强调色填充配白字是 3.65:1，而任何单一深色值都无法同时满足
                // 「小字压在卡片上 ≥ 4.5」与「填充配白字 ≥ 4.5」（论证见 `AppTheme.accent` 文档），
                // 取舍是保小字可读。**不要**改这一处颜色，也不要引入新的硬编码色。
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        // 强调层贴胶囊轮廓，避免按下瞬间两端露出方角（U0-4）。
        .buttonStyle(PressableCardButtonStyle(pressedScale: 0.96, shape: AnyShape(Capsule())))
    }
}

// MARK: - 书目行

/// 书城的书目行（照抄 `SearchView.swift:256-313` 的 `SearchResultRow` 卡面）：
/// 封面占位 + 书名 + 作者，整卡可点、按下有反馈、push 详情页。
/// 与搜索结果卡的差异只有一处：这里**没有**行尾的「加入书架」按钮
/// —— 加书入口统一在详情页，由 `onAddedToShelf` 回写书架。
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
