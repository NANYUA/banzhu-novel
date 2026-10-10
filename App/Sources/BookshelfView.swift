import ComposableArchitecture
import NovelCore
import SwiftUI

/// 书架列表（docs/03 §二 · §三，D15 = SwiftUI List）。
///
/// ## 与 Reducer 的分工
/// 本文件**只管展示和用户交互**，不碰任何业务逻辑。
/// 所有状态变化都通过 `store.send(...)` 走 `BookshelfFeature`，
/// 测试可以单独跑 reducer（不启动界面），也可以单独跑本 View（注入内存 store）。
///
/// ## 为什么用 WithViewStore 而不是 store.state / store.foo
/// `store.state` 和动态成员都要求 `State: ObservableState`（`@ObservableState` 宏）。
/// 但宏插件在 Xcode 16.4 的 xcodebuild 下跑不起来（本项目因此手写 Reducer 协议）。
/// `WithViewStore` 是 TCA 的传统观察方式，走 Combine，不依赖任何宏 ——
/// 在「宏在 CI 上不可靠」的前提下这是唯一稳定的观察路径。
///
/// ## 行布局
/// ```
/// ┌────────┐  书名
/// │        │  作者
/// │  封面  │  上次读到：…
/// │        │  最新章节：…
/// └────────┘          [未读 N 章]
/// ```
struct BookshelfView: View {
    let store: StoreOf<BookshelfFeature>
    let downloadStore: StoreOf<DownloadFeature>

    // ⚠️ 下面三个刻意**不是** `private`：分组栏已拆到 `BookshelfView+GroupBar.swift`，
    // 而跨文件的 extension 读不到 file-private 状态（`newGroupName` 只在本文件用，保持 `private`）。
    @State var isShowingNewGroupAlert = false
    @State private var newGroupName = ""
    @State var renamingGroup: ShelfGroupSnapshot?
    @State var renameGroupName = ""
    @State private var isConfirmingDelete = false
    /// U9-8：「下载设置」sheet 的开关。入口在本地分组（= 下载队列）下的工具栏里，
    /// 所以这个状态与 `showsLocalGroup` 同生共死；`private` 足够（同文件的 extension 读得到）。
    @State private var isShowingDownloadSettings = false
    /// 详情页目标。用显式 push 而不是 `NavigationLink`：见 `rowContent` 的注释。
    @State private var detailRow: ShelfRow?
    @State private var isShowingDetail = false
    /// 最近一次长按时间：用来挡掉长按抬手时 Button 多触发的那次点击。
    @State private var lastLongPressAt: Date?

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 0) {
                    groupBar(viewStore)

                    ZStack {
                        if viewStore.showsLocalGroup {
                            // 「本地」固定分组的内容 = 下载队列。整页复用 `DownloadQueueView`，
                            // 不复制它的实现；分组栏仍在它上方，用户随时能切走。
                            // 它不读 `visibleRows`：本地分组不参与书目过滤。
                            DownloadQueueView(store: downloadStore)
                        } else if viewStore.isLoading, viewStore.rows.isEmpty {
                            // 首次加载中，还没数据也不确定是否失败
                            ProgressView("加载中…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let message = viewStore.errorMessage, viewStore.rows.isEmpty {
                            // 加载失败 + 无数据 → 显示错误 + 重试
                            VStack(spacing: DesignTokens.Spacing.md) {
                                Text("加载失败")
                                    .font(.title3.bold())
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // HIG §9：系统 `.borderedProminent` 默认约 34pt 高，
                                // `.controlSize(.large)` 把它抬到 44pt 命中区。
                                Button("重试") {
                                    viewStore.send(.onAppear)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if viewStore.visibleRows.isEmpty {
                            emptyState
                        } else {
                            shelfList(viewStore)
                        }
                    }
                    // 自撑满：ZStack 只剩 `emptyState` 一个子视图时不能跟着 CUV 缩水，否则分组栏会被整体居中。
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // U1-1：页面底 = 浅色分组灰（`AppTheme.Surface.page`），卡面 = 白（`AppTheme.Surface.card`），
                // 两者形成一级层次。分组栏、加载 / 空 / 错误态透出页面色；
                // 白底只留给列表里的行卡片本身。
                .background(AppTheme.Surface.page)
                .navigationTitle("书架")
                // 底栏（tabBar）可见性的**唯一所有者**就是每个 tab 根视图，且由状态驱动：
                // 详情页 / 阅读页都不再自己声明底栏，泄漏在构造上不可能发生。
                // 两种偏好解析模型下行为都正确 ——
                // · 若「根视图声明胜出」：push 详情期间根的状态是 `.hidden` ⇒ 详情页没有底栏；
                //   回到根时状态翻回 `.visible` ⇒ 底栏可靠恢复；
                // · 若「最上层声明胜出」：被 push 的视图不再声明，最上层声明者就是根 ⇒ 同样按状态走。
                .toolbar(isShowingDetail ? .hidden : .visible, for: .tabBar)
                // 底栏**背景**同样由根视图声明为「始终可见」：iOS 15+ 的底栏有 scroll-edge 外观，
                // 内容没滚动（空态 / 列表不够长）时背景本来就是透明的 —— 真机「底栏偶尔变透明」就是它。
                // 与上面的可见性同一层声明（`.toolbar(_, for: .tabBar)` 在这层已被真机验证有效）；
                // 阅读页整条底栏是 `.hidden`，背景可见与否都看不见，专注模式不受影响。
                .toolbarBackground(.visible, for: .tabBar)
                // U9-8：这里**原先**有一条 `.toolbar(showsLocalGroup ? .hidden : .visible, for: .navigationBar)`。
                // 它的成因是「同屏两条导航栏」——「本地」分组的内容 `DownloadQueueView` 自带一层
                // `NavigationStack`（「下载」标题 + 齿轮），外层这层再画一条就成了两条；
                // 于是本地态把**外层**栏整条藏掉，让内层占据顶部（批量工具栏也被一起藏掉）。
                // 那条已撤掉：`DownloadQueueView` 不再自带 `NavigationStack`，只剩这一层，
                // 标题统一为下面的「书架」。owner 口径是「书架的本地页应该完全融入书架页面，
                // 遵从书架的风格」—— 留一个「下载」大标题恰恰是"看起来像嵌进来的另一个 App"的来源。
                // 分组胶囊栏在 `body` 里、不在导航栏里，所以不受这条改动影响，随时能切回「全部」。
                // ⚠️ 撤掉它之后批量工具栏会在本地态露出来 —— 那由 `toolbarContent` 里
                // `!viewStore.showsLocalGroup` 那条护栏挡住，**不要**把那条护栏一起删掉。
                //
                // `.navigationBar` 与上面的 `.tabBar` 是两个独立的 `ToolbarPlacement`；
                // 这里不再对 `.navigationBar` 做可见性声明（默认可见即所要的效果）。
                .onAppear { viewStore.send(.onAppear) }
                .navigationDestination(isPresented: $isShowingDetail) {
                    if let row = detailRow {
                        BookDetailView(
                            bookPath: row.bookPath,
                            title: row.title,
                            downloadStore: downloadStore,
                            // 详情页里移出 / 重新加入书架后，书架列表立刻跟上，
                            // 不依赖「返回时重拉一次」这种时序假设。
                            onAddedToShelf: { added in viewStore.send(.addSucceeded(added)) },
                            onRemovedFromShelf: { bookPath in
                                viewStore.send(.booksDeleted([bookPath]))
                            }
                        )
                    }
                }
                .toolbar {
                    toolbarContent(viewStore)
                }
                // U9-8：「下载设置」的载体。它**自带一层 `NavigationStack`** ——
                // 所以撤掉 `DownloadQueueView` 自己那层栈，不影响设置页的标题与「完成」按钮。
                // sheet 挂在书架这一层而不是 `DownloadQueueView` 里：入口按钮现在归外层工具栏所有，
                // 两者必须共用同一个开关（`isShowingDownloadSettings`）。
                .sheet(isPresented: $isShowingDownloadSettings) {
                    NavigationStack {
                        DownloadSettingsView(store: downloadStore)
                    }
                }
                .alert("新建分组", isPresented: $isShowingNewGroupAlert) {
                    TextField("分组名", text: $newGroupName)
                    Button("创建") {
                        viewStore.send(.createGroup(newGroupName))
                        newGroupName = ""
                    }
                    Button("取消", role: .cancel) {
                        newGroupName = ""
                    }
                }
                .alert(
                    "重命名分组",
                    isPresented: Binding(
                        get: { renamingGroup != nil },
                        set: {
                            if !$0 {
                                renamingGroup = nil
                            }
                        }
                    )
                ) {
                    TextField("分组名", text: $renameGroupName)
                    Button("保存") {
                        if let group = renamingGroup {
                            viewStore.send(.renameGroup(group.id, renameGroupName))
                        }
                        renamingGroup = nil
                        renameGroupName = ""
                    }
                    Button("取消", role: .cancel) {
                        renamingGroup = nil
                        renameGroupName = ""
                    }
                }
                .confirmationDialog(
                    "删除选中的 \(viewStore.selectedBookPaths.count) 本书？",
                    isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        for path in viewStore.selectedBookPaths {
                            downloadStore.send(.cancelBook(path))
                        }
                        viewStore.send(.deleteSelectedBooks)
                    }
                    Button("取消", role: .cancel) {}
                }
                .onChange(of: viewStore.pendingDownloadRequests) { _, requests in
                    guard !requests.isEmpty else { return }
                    downloadStore.send(.enqueue(requests))
                    viewStore.send(.batchDownloadConsumed)
                }
            }
        }
    }
}

// MARK: - 工具栏

private extension BookshelfView {
    @ToolbarContentBuilder
    func toolbarContent(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some ToolbarContent {
        // 🔴 `!viewStore.showsLocalGroup` 是 U9-8 的回归护栏，纯 View 层，**不要**改成动 reducer：
        // `.groupSelected` / `.localGroupSelected` 都**不重置** `isEditing`（`BookshelfFeature.swift:147-162`），
        // 而批量工具栏的唯一渲染条件就是 `isEditing`。U9-8 之前这里没暴露，只因
        // `body` 里那条 `.toolbar(showsLocalGroup ? .hidden : .visible, for: .navigationBar)`
        // 把整条导航栏连工具栏一起藏掉了；U9-8 撤掉那条之后，本地分组（= 下载队列）会
        // 长出「全选 / 整本下载 / 移入分组 / 删除」——本地分组装的是下载任务、不是书目，
        // 这些批量操作在语义上根本不成立，而且「全选」的判据 `visibleRows` 在本地态也拿不到书。
        // 因此渲染条件补上 `!showsLocalGroup`：与 reducer 里「本地与书组互斥」的不变量同向。
        if viewStore.isEditing, !viewStore.showsLocalGroup {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") {
                    viewStore.send(.editModeChanged(false))
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    selectAllMenuItem(viewStore)

                    Button {
                        viewStore.send(.downloadSelectedBooks)
                    } label: {
                        Label("整本下载", systemImage: "arrow.down.circle")
                    }
                    .disabled(viewStore.selectedBookPaths.isEmpty)

                    Menu("移入分组") {
                        Button("未分组") {
                            viewStore.send(.assignSelectedBooks(nil))
                        }
                        ForEach(viewStore.groups) { group in
                            Button(group.name) {
                                viewStore.send(.assignSelectedBooks(group.id))
                            }
                        }
                    }
                    .disabled(viewStore.selectedBookPaths.isEmpty)

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(viewStore.selectedBookPaths.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                // ⚠️ `.disabled` 从 Menu 挪到了各菜单项上：整本下载 / 移入分组 / 删除
                // 依赖「有选中」，而「全选」恰恰是在**还没选中任何书**时才要点的。
                // 留在 Menu 上会让全选在唯一需要它的状态下点不到。
                .accessibilityLabel("批量操作")
            }
        }

        downloadSettingsToolbarItem(viewStore)
    }

    /// U9-8：「下载设置」入口 —— **只在本地分组（= 下载队列）下出现**。
    ///
    /// 与上面的批量菜单**互斥**（后者要求 `!showsLocalGroup`），两者永不共存，
    /// 所以都占 `.topBarTrailing` 也不会打架。
    ///
    /// 单独成函数是为了压 `toolbarContent` 的 `function_body_length`
    /// （SwiftLint warning 50 / error 60，判定严格 `>`）：内联进去会把那个函数顶到 49 行，
    /// 贴着 warning 门槛，日后任何小改都会把 CI 打红。
    @ToolbarContentBuilder
    func downloadSettingsToolbarItem(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some ToolbarContent {
        if viewStore.showsLocalGroup {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingDownloadSettings = true
                } label: {
                    Label("下载设置", systemImage: "gearshape")
                }
            }
        }
    }

    /// 「全选 / 取消全选」菜单项。
    ///
    /// 单独成函数是为了压 `toolbarContent` 的 `function_body_length`
    /// （SwiftLint warning 50 / error 60，判定严格 `>`）—— 那个函数已贴着上限。
    ///
    /// 按钮只负责发 `.toggleSelectAllVisible`，集合运算全在 reducer 里：
    /// 全选范围 = `State.visibleRows`（分组过滤后用户真正看得到的行）。
    func selectAllMenuItem(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        Button {
            viewStore.send(.toggleSelectAllVisible)
        } label: {
            Label(
                viewStore.areAllVisibleRowsSelected ? "取消全选" : "全选",
                systemImage: viewStore.areAllVisibleRowsSelected ? "circle" : "checkmark.circle"
            )
        }
        .disabled(viewStore.visibleRows.isEmpty)
    }
}

// MARK: - 列表

private extension BookshelfView {
    /// 空状态（§10 Wayfinding）：没有书时也要回答「有什么 / 怎么加书」。
    var emptyState: some View {
        ContentUnavailableView(
            "书架为空",
            systemImage: "books.vertical",
            description: Text("在「搜索」页找到想读的书，加入书架后会显示在这里。")
        )
    }

    func shelfList(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        List(viewStore.visibleRows) { row in
            rowContent(row, viewStore: viewStore)
                .listRowSeparator(.hidden)
                .listRowInsets(
                    .init(
                        top: DesignTokens.Spacing.xs,
                        leading: DesignTokens.Spacing.md,
                        bottom: DesignTokens.Spacing.xs,
                        trailing: DesignTokens.Spacing.md
                    )
                )
                // 行背景清掉：卡面颜色由 `BookRow` 自己画（`AppTheme.Surface.card`），
                // 这里再铺一层 List 默认的 `systemBackground`（浅色纯白）会把行卡片之间
                // 的间隙也涂白，卡片就与页面分不出层次了。
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        // 让 List 自己的滚动背景透出页面分组灰。
        .scrollContentBackground(.hidden)
        .refreshable {
            await viewStore.send(.onAppear).finish()
        }
    }

    @ViewBuilder
    private func rowContent(
        _ row: ShelfRow,
        viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        if viewStore.isEditing {
            let isSelected = viewStore.selectedBookPaths.contains(row.bookPath)
            Button {
                viewStore.send(.selectionToggled(row.bookPath))
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
                        // 装饰性图形：选中语义交给 Button 的 `.isSelected` trait，避免它被单独读成一个元素。
                        .accessibilityHidden(true)
                    BookRow(row: row)
                }
            }
            // 编辑态整行都是按钮，强调层贴整行的 12pt 圆角（与行卡一致），不在圆角外露方角。
            .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            // 🔴 这里刻意不用 NavigationLink：它的点击手势会和长按手势抢识别，
            // 结果「点书进不去详情」（长按进编辑是既有交互，不能砍）。
            // 用 Button 拿到按下反馈（HIG：按下即反馈），长按用 simultaneousGesture
            // 并行识别；长按抬手时 Button 也会触发一次 action，用时间戳挡掉。
            Button {
                guard !isLongPressSuppressed else { return }
                detailRow = row
                isShowingDetail = true
            } label: {
                BookRow(row: row)
            }
            // 强调层贴书卡自己的 8pt 圆角，避免按下瞬间在圆角外露出方角（U0-4）。
            .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))))
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    lastLongPressAt = Date()
                    viewStore.send(.editModeChanged(true))
                }
            )
        }
    }

    /// 长按抬手后 Button 也会收到一次 action，这里挡掉，避免「长按同时跳详情」。
    private var isLongPressSuppressed: Bool {
        guard let lastLongPressAt else { return false }
        return Date().timeIntervalSince(lastLongPressAt) < 0.4
    }
}

// MARK: - 单行

private struct BookRow: View {
    let row: ShelfRow

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // 封面
            AsyncImage(url: URL(string: row.coverUrl)) { phase in
                switch phase {
                case .empty:
                    placeholder
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 60, height: 80)
            .background(AppTheme.Surface.inset)
            .cornerRadius(DesignTokens.Radius.sm)

            // 文字区
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(row.author.isEmpty ? "未知作者" : row.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let last = row.lastReadChapterName {
                    Text("上次读到：\(last)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let latest = row.latestChapterName {
                    Text("最新章节：\(latest)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 未读章数 badge
            if row.unreadCount > 0 {
                Text("\(row.unreadCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(AppTheme.statusDanger, in: Circle())
            }
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

    private var placeholder: some View {
        Rectangle()
            .fill(AppTheme.Surface.inset)
            .overlay {
                Image(systemName: "book")
                    .font(.title3)
                    .foregroundStyle(.quaternary)
            }
    }
}

// MARK: - Preview

#Preview {
    let store = Store(initialState: BookshelfFeature.State(
        rows: [
            ShelfRow(
                bookPath: "/49/49034/",
                title: "楚香君游戏",
                author: "某某某",
                coverUrl: "",
                lastReadChapterName: "第七章 夜探皇宫",
                latestChapterName: "第九章 风云起",
                unreadCount: 12,
                lastReadAt: Date()
            ),
            ShelfRow(
                bookPath: "/49/49035/",
                title: "另一本书",
                author: "",
                coverUrl: "",
                lastReadChapterName: nil,
                latestChapterName: "第一章",
                unreadCount: 0,
                lastReadAt: nil
            ),
        ],
        isLoading: false,
        errorMessage: nil
    )) {
        BookshelfFeature()
    }
    let downloadStore = Store(initialState: DownloadFeature.State()) {
        DownloadFeature()
    }
    BookshelfView(store: store, downloadStore: downloadStore)
}
