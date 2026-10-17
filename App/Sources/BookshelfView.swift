import ComposableArchitecture
import Dependencies
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

    /// 阅读落点解析（整本目录 + 上次读到哪一章哪个偏移）。依赖注入 ⇒ 测试可换成桩。
    /// ⚠️ 刻意**不是** `private`：这条链路已拆到 `BookshelfView+Reader.swift`。
    @Dependency(\.readingTargetLoader) var readingTargetLoader

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
    // ⚠️ 下面五个刻意**不是** `private`：「进阅读页」那条链路已拆到
    // `BookshelfView+Reader.swift`，而跨文件的 extension 读不到 file-private 状态
    // （与 `isShowingNewGroupAlert` 那组同一处理）。

    /// 阅读页目标（整本目录 + 落点）。用显式 push 而不是 `NavigationLink`：见 `rowContent` 的注释。
    @State var readerTarget: ReadingTarget?
    /// 进阅读页时要带过去的书名（HUD 左上角在章节第一页显示它）。
    ///
    /// 由 `prepareReader` 写入 —— 书名**从入口那层传进来**，不在这里按 `bookPath` 反查：
    /// 下载页可能有不带书架行的书，反查会静默拿到空标题。
    @State var readerBookTitle = ""
    @State var isShowingReader = false
    /// 正在准备阅读的书路径。非 `nil` = 正在取目录 ⇒ 全页进度覆盖层，
    /// 避免「点了卡片半天没反应」（取目录是异步的，见 `prepareReader`）。
    @State var preparingBookPath: String?
    /// 准备失败的提示。非 `nil` = 弹 alert —— 取目录失败**不静默**。
    @State var prepareErrorMessage: String?
    /// 正在被按下的那一行（`nil` = 没有行被按下）—— 手势版书卡的**按下高亮**靠它。
    ///
    /// ## 为什么是「路径」而不是 `Bool`
    /// 这一层是 `List` 里的**多行**，每行各自挂手势；用一个 `Bool` 无法区分「哪一行被按下」。
    /// 按下时写入该行的 `bookPath`、抬手清空 ⇒ 只有被按的那一行高亮。
    ///
    /// ⚠️ 刻意**不加 `private`**：本文件对「被同文件其它 extension 读取的状态」沿用不加 `private`
    /// 的写法（与 `readerTarget` 那一组一致）。
    @State var pressedBookPath: String?

    // 导入本地 TXT（owner 2026-10-17）：picker 开关 / 选中的文件 / 选文件失败的提示。
    // 状态留在这里、呈现挂在 `BookshelfView+Import.swift` —— 工具栏里的子视图不是稳定宿主，
    // 把 `.fileImporter` / `.sheet` 挂在它上面真机上「点了没反应」（见 `ImportTXTButton` 注释）。
    // ⚠️ 同样刻意不加 `private`：`BookshelfView+Import.swift` 的 extension 要读它们。
    @State var isPickingImportFile = false
    @State var pickedImportFile: PickedImportFile?
    @State var importFailureMessage: String?

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 0) {
                    // U13：分组栏还收下载队列的 store —— 选择模式的「完成」出口钉在它最右边
                    // （原先在下载页常驻上栏里）。状态判据与布局都在 `groupBar` 内，见该函数说明。
                    groupBar(viewStore, downloadStore: downloadStore)

                    ZStack {
                        if viewStore.showsLocalGroup {
                            // 「本地」固定分组的内容 = 下载队列。整页复用 `DownloadQueueView`，
                            // 不复制它的实现；分组栏仍在它上方，用户随时能切走。
                            // 它不读 `visibleRows`：本地分组不参与书目过滤。
                            //
                            // `onOpenBook` 把「单点书卡 ⇒ 直接进阅读页」的落点决策**留在这层**：
                            // 阅读页是 push 在本页的 `NavigationStack` 上的，准备态 / 失败提示 /
                            // 底栏显隐都只有这一处所有者（见 `prepareReader`）。
                            DownloadQueueView(
                                store: downloadStore,
                                onOpenBook: { bookPath, bookTitle in
                                    prepareReader(bookPath: bookPath, bookTitle: bookTitle)
                                }
                            )
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
                // 取目录期间的全页覆盖层 + 失败提示（实现在 `BookshelfView+Reader.swift`）。
                .readerPreparation(
                    isPreparing: preparingBookPath != nil,
                    failureMessage: $prepareErrorMessage
                )
                // 导入 TXT 的呈现宿主（picker / 填书名 sheet / 失败提示）。
                // 挂在内容层而不是工具栏：工具栏子视图不是稳定宿主（见 `ImportTXTButton` 注释）。
                .importHost(
                    isPicking: $isPickingImportFile,
                    picked: $pickedImportFile,
                    failureMessage: $importFailureMessage,
                    onImported: { viewStore.send(.onAppear) }
                )
                .navigationTitle("书架")
                // 底栏（tabBar）可见性的**唯一所有者**就是每个 tab 根视图，且由状态驱动：
                // 阅读页不自己声明底栏（`ReaderView` 里有注释说明为什么），泄漏在构造上不可能发生。
                // 两种偏好解析模型下行为都正确 ——
                // · 若「根视图声明胜出」：push 阅读页期间根的状态是 `.hidden` ⇒ 阅读页没有底栏；
                //   回到根时状态翻回 `.visible` ⇒ 底栏可靠恢复；
                // · 若「最上层声明胜出」：被 push 的视图不再声明，最上层声明者就是根 ⇒ 同样按状态走。
                .toolbar(isShowingReader ? .hidden : .visible, for: .tabBar)
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
                // owner 2026-10-11 口径：**选择模式不常驻** —— 离开「本地」分组（= 下载队列）就退出下载选择模式。
                //
                // ## 为什么是「离开本地」而不是「点某个胶囊」
                // 下载选择模式只在「本地」分组里有意义。用「分组状态本身的变化」当判据，
                // 就**只有这一处**真相：给每个胶囊各写一次会变成三处，且漏掉「从别处切回全部」等路径。
                //
                // ## 为什么书架编辑态不在这里退
                // 那个状态住在 `BookshelfFeature`，由 reducer 在 `.groupSelected` / `.localGroupSelected`
                // 里自己退（见 `exitEditing`）—— reducer 能做的事不要搬到视图层。
                //
                // 幂等：`applySelectionMode(false)` 在已经是退出态时不改变任何状态（见 `DownloadFeature+Selection`）。
                .onChange(of: viewStore.showsLocalGroup) { _, showsLocal in
                    guard !showsLocal else { return }
                    downloadStore.send(.selectionModeChanged(false))
                }
                // 单点书卡 ⇒ **直接进阅读页**（owner 需求：书架 / 本地 / 分组都不再进详情页）。
                // 详情页入口改在阅读页右上角「更多」里；目标与准备链路见 `BookshelfView+Reader.swift`。
                .navigationDestination(isPresented: $isShowingReader) {
                    readerDestination
                }
                // 从阅读页回来时重拉一次书架：`lastReadAt` / `上次读到` / 未读章数
                // 都是刚刚读出来的新值，不重拉就会停在旧快照上。
                // `.onAppear` 幂等、且**不会**退出编辑态（只有「切分组」与「切 tab」才退出，
                // 见 `exitEditing` 与 `RootView` 的 `.onChange(of: selectedTab)`），重发安全。
                .onChange(of: isShowingReader) { _, isShowing in
                    guard !isShowing else { return }
                    viewStore.send(.onAppear)
                }
                .toolbar {
                    toolbarContent(viewStore)
                    // 导入本地 TXT（owner 2026-10-17 口径：只做 App 内选择文件，
                    // 不做「用其它 App 打开」的 Info.plist 入口）。
                    // 这里**只开开关**：picker 与导入 sheet 挂在下面的 `.importHost(...)` 上，
                    // 导入成功后重发 `.onAppear` 让书架重拉一次（与「从阅读页返回」同一条刷新路径）。
                    ToolbarItem(placement: .topBarTrailing) {
                        ImportTXTButton { isPickingImportFile = true }
                    }
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
        // 🔴 `!viewStore.showsLocalGroup` 是 U9-8 的回归护栏，纯 View 层，**不要**去掉 ——
        // 批量工具栏的唯一渲染条件就是 `isEditing`。
        // ⚠️ 2026-10-11 起切分组会**退出编辑态**（`exitEditing`，owner 口径「选择模式不常驻」）
        // ⇒ 正常路径下本地态已经不会有 `isEditing`；这条护栏仍要留着（双保险，不依赖那条新行为）。
        // U9-8 之前这里没暴露，只因
        // `body` 里那条 `.toolbar(showsLocalGroup ? .hidden : .visible, for: .navigationBar)`
        // 把整条导航栏连工具栏一起藏掉了；U9-8 撤掉那条之后，本地分组（= 下载队列）会
        // 长出「全选 / 整本下载 / 移入分组 / 删除」——本地分组装的是下载任务、不是书目，
        // 这些批量操作在语义上根本不成立，而且「全选」的判据 `visibleRows` 在本地态也拿不到书。
        // 因此渲染条件补上 `!showsLocalGroup`：与 reducer 里「本地与书组互斥」的不变量同向。
        //
        // ⚠️ 这个判据现在**只**管右边那个批量操作菜单：原先与它成对的「完成」按钮
        // （`ToolbarItem(placement: .topBarLeading)`）已按 owner 第十轮第 3 条**搬到分组栏最右边**
        // （`BookshelfView+GroupBar.swift` 的 `selectionDoneChip`，判据 `isEditing && !showsLocalGroup`
        // 与这里同源）。⇒ 导航栏左上角**不再**有「完成」，别再往这里加回去。
        if viewStore.isEditing, !viewStore.showsLocalGroup {
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
            // 结果「点书进不去阅读页」（长按进编辑是既有交互，不能砍）。
            //
            // ⛔ 也**不再用 `Button` + `.simultaneousGesture(LongPressGesture)`**（2026-10-11 真机缺陷的根因）：
            // 那个组合会把 `Button` **自己的按压手势挤掉** ⇒ ① 单击连按下变色都没有（owner 原话）；
            // ② 快速单击的 action 不触发（点书进不去阅读页）；③ action 只在长按抬手时走一次
            // ⇒「长按进编辑态」顺手进了阅读页。现在改用 SwiftUI **有文档保证**的仲裁：
            // `onTapGesture` 与 `onLongPressGesture` 挂在**同一个视图**上 ⇒ 按住 ≥ 0.5s **只**走长按、
            // 快速点**只**走 tap ⇒ **不需要任何标志、也不依赖回调顺序**
            // （原先那套「长按已识别」标志已整体删除；与 `DownloadBookCard` 是同一套做法）。
            BookRow(row: row)
                .contentShape(Rectangle())
                .onTapGesture {
                    prepareReader(
                        bookPath: row.bookPath,
                        bookTitle: row.title,
                        progressHint: progressHint(of: row)
                    )
                }
                .onLongPressGesture(
                    minimumDuration: 0.5,
                    perform: { viewStore.send(.editModeChanged(true)) },
                    // ⚠️ `onPressingChanged` 是 iOS 17 起的**当前签名**（旧的 `pressing:` 已弃用：
                    // 用它会在编译日志里留一条弃用警告，而本项目要求警告为 0）。
                    onPressingChanged: { isPressing in
                        pressedBookPath = isPressing ? row.bookPath : nil
                    }
                )
                // 强调层贴书卡自己的 12pt 圆角（`Radius.sm`），避免按下瞬间在圆角外露出方角（U0-4）。
                // 取值与 `PressableCardButtonStyle` 逐值相同（都来自 `PressHighlightMetrics`）。
                .pressHighlight(
                    isPressed: pressedBookPath == row.bookPath,
                    shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                )
                // 手势版没有 Button ⇒ 显式补上「这是个按钮」与它的激活动作（否则 VoiceOver 只能读、不能点）。
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    prepareReader(
                        bookPath: row.bookPath,
                        bookTitle: row.title,
                        progressHint: progressHint(of: row)
                    )
                }
        }
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
