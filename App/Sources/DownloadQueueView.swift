import ComposableArchitecture
import Dependencies
import NovelCore
import SwiftUI

/// 下载管理页：总进度、分书书卡、暂停/重试与下载设置。
///
/// ## U9-8：从「自带导航栏的独立页」变成「书架『本地』分组的内容视图」
/// 全仓唯一调用点是 `BookshelfView.swift:54`。本视图现在：
/// - **不再自带 `NavigationStack`** —— 原先它与 `BookshelfView` 的栈叠成两层
///   （屏幕上只剩内层那条，外层被 `BookshelfView` 的 `.toolbar(_, for: .navigationBar)` 藏掉）；
///   现在只保留外层那一条；
/// - **不再声明 `.navigationTitle("下载")`** —— 本地页标题统一为外层栏的「书架」。
///   owner 口径是「书架的本地页应该完全融入书架页面，遵从书架的风格」，
///   而留一个「下载」大标题恰恰是"看起来像嵌进来的另一个 App"的来源；
/// - 「下载设置」入口搬到 `BookshelfView` 的外层工具栏（**仅 `showsLocalGroup` 时出现**），
///   故 `DownloadSettingsView` 由 `private` 放宽到 `internal` 供其引用。
///
/// ## U9-8：视觉语言对齐书架（**对项目待办清单第 73 行登记的取舍做的一次显式翻转**）
/// 原先 `.listStyle(.insetGrouped)`（系统分组行 + 系统卡片圆角）与书架的
/// `.plain` + `scrollContentBackground(.hidden)` + 自绘卡（`Surface.card` + `Radius.sm`）并存，
/// 该取舍在工作区根目录的待办清单第 73 行被登记为「结构性取舍，需产品决策」—— U9-8 就是那个决策：
/// （那份清单的文件名刻意不写在这里：它含一个小写词，会被 SwiftLint 的「待办标记」规则盯上，
/// 而本机没有 SwiftLint 二进制、无法验证那条规则的大小写敏感性 —— 不赌。）
/// **翻转到 `.plain`**，与书架同源。层次 = 页面底（`Surface.page` 分组灰）
/// → 卡（`Surface.card` 白）→ 卡内行。
///
/// ## U10：逐章任务行 → 书籍卡片
/// owner 口径：本地页显示成**书籍卡片**，**已下载的章节不在队列里逐条列**
/// （去书籍阅读界面的目录里看）。所以每本书只剩一张卡，进度与状态写在卡面上，
/// 卡面观感与书架书卡同源，长按进选择模式（本地页自带一条批量操作栏）。
/// 原先的「书名 header」（`DownloadBookHeader`）与逐章行（`DownloadTaskRow`）随之删除；
/// 书卡与选择模式 UI 拆在 `DownloadBookCard.swift`。
/// **队列级的东西照旧**：提示条、总进度（全部暂停 / 重试失败 / 验证后重试）都保留。
struct DownloadQueueView: View {
    let store: StoreOf<DownloadFeature>

    /// 单点书卡 → 直接进阅读页。落点决策与准备态都留在**书架那一层**
    /// （阅读页 push 在书架的 `NavigationStack` 上，覆盖层与底栏显隐只有那一处所有者）。
    ///
    /// 两个参数是 `(bookPath, 书名)`：书名由本页的 `BookDownloadSummary.title` 提供，
    /// 供阅读页角落标签用（不按 `bookPath` 反查书库 —— 下载页可能有不带书架行的书）。
    ///
    /// ⚠️ 书名为 `nil`（书库与快照都没有）时传空串：阅读页角落标签对空书名的既有处理是
    /// **回退只显示章节名**，且该书本来就不在书库、拿不到真名 —— 这是可接受的下限，不是回归。
    /// 若用户在阅读页再点「下载本章」，入队的 `bookTitle` 也会是空串，同样源于取不到真名。
    let onOpenBook: (String, String) -> Void

    /// 书卡的**书名 / 作者 / 封面**的唯一来源：按 `bookPath` 从书库查（`BookLibraryMetaLoader`）。
    ///
    /// 书名与作者优先取书库（`BookRecord`）、快照只当兜底，取值顺序见 `BookDownloadSummary`——
    /// 这样历史脏数据（快照里 `bookTitle == ""`）在显示时自愈。
    @Dependency(\.bookLibraryMetaLoader) private var bookLibraryMetaLoader

    /// `bookPath → BookLibraryMeta`。**不在 `body` 里逐卡查库**：随 `bookPaths` 变化拉一次，
    /// 书卡只做内存查表 —— `List` 滚动时不再读库。
    @State private var bookMetas: [String: BookLibraryMeta] = [:]

    /// 待确认「删除下载」的书（非空即弹确认框）。
    ///
    /// 「删除下载」会连已下载正文一起清掉、不可逆，按 HIG §11 先确认一次
    /// （书架批量删书同样是先确认再删）。
    @State private var pendingDeletePaths: [String] = []

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            Group {
                if viewStore.tasks.isEmpty {
                    emptyState
                } else {
                    queueList(viewStore)
                }
            }
            // 先显式撑满再铺底：`Group` 布局透明，`.background` 只覆盖被修饰视图的 frame，而空态是裸 CUV。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // U1-1：空态与列表态共用同一张页面底（`AppTheme.Surface.page`）。
            // 挂在 `Group` 上而不是只给 `emptyState` 单独刷一层：两条分支只有一处真相源，日后不会漂移。
            .background(AppTheme.Surface.page)
            // 原先挂在 `NavigationStack` 上；U9-8 去掉那层栈后改挂这里，行为不变：
            // 切到「本地」分组时本视图出现 ⇒ 拉一次队列快照。
            .onAppear {
                viewStore.send(.task)
            }
            // 书名 / 作者 / 封面：队列里的书目变了才拉一次（一次读库；查不到的书回退快照与占位块）。
            .task(id: viewStore.bookPaths) {
                let paths = viewStore.bookPaths
                guard !paths.isEmpty else {
                    bookMetas = [:]
                    return
                }
                bookMetas = await (try? bookLibraryMetaLoader.load(paths)) ?? [:]
            }
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: Binding(
                    get: { !pendingDeletePaths.isEmpty },
                    set: {
                        if !$0 {
                            pendingDeletePaths = []
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("删除下载", role: .destructive) {
                    viewStore.send(.deleteDownloads(pendingDeletePaths))
                    pendingDeletePaths = []
                }
                Button("取消", role: .cancel) {
                    pendingDeletePaths = []
                }
            } message: {
                Text("会取消这些书的下载并删除已下载的正文；书架上的书会保留，可随时重新下载。")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无下载",
            systemImage: "arrow.down.circle",
            description: Text("可在书籍目录中下载单章或整本。")
        )
    }

    /// 删除确认框的标题（由 `@State` 驱动，故单独成属性）。
    private var deleteDialogTitle: String {
        if pendingDeletePaths.count == 1 {
            return "删除这本书的下载？"
        }
        return "删除选中的 \(pendingDeletePaths.count) 本书的下载？"
    }

    /// 本地页：**上栏（进度卡片 / 选择卡片）常驻**，只有书卡列表滚动。
    ///
    /// 卡片原先占 `List` 里那个 `Section` 的第一行 ⇒ 随列表滚走；owner 口径「进度卡片（选择卡片）
    /// 向上滑动 … 作为上栏，下方已下载的书籍从这个上栏的下方走」⇒ 现在与 `List` **并列**放进
    /// `VStack`，滚动内容从卡片下沿之下开始。⚠️ 不用「`List` 内的吸顶 Section header」：header 的
    /// 横向内缩规则与行不同源、卡片会与书卡左右对不齐；放 `List` 外则由 `pinnedHeader` 的
    /// `.padding(.horizontal, Spacing.md)` 显式给出，与书卡行的 `.downloadQueueRow()`（即书架列表那套
    /// `.listRowInsets`）**同一个令牌**。
    private func queueList(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        VStack(spacing: 0) {
            pinnedHeader(viewStore)
                // 补回卡片搬出 `List` 后失效的那条 bottom 内缩（`Spacing.xs`），间距不变。
                .padding(.bottom, DesignTokens.Spacing.xs)

            List {
                if let notice = viewStore.notice {
                    Section {
                        DownloadNoticeRow(notice: notice) {
                            viewStore.send(.noticeDismissed)
                        }
                        .downloadQueueCard()
                    }
                }

                // 「重试失败项（n）」「验证后重试（n）」仍留在 `List` 顶部（不属于上栏）；
                // 顺序与出现条件逐字不变：只在**非选择模式**下出现。
                if !viewStore.isSelecting {
                    if viewStore.failedCount > 0 {
                        retryFailedRow(viewStore)
                    }

                    if viewStore.blockedCount > 0 {
                        retryBlockedRow(viewStore)
                    }
                }

                ForEach(bookSummaries(from: viewStore.tasks, order: viewStore.bookPaths, metas: bookMetas)) { summary in
                    bookCard(summary, viewStore: viewStore)
                }
            }
            .listStyle(.plain)
            // 让 List 自己的滚动背景透出页面分组灰（与书架 `shelfList` 同一手法）。
            .scrollContentBackground(.hidden)
        }
    }

    /// 常驻上栏：进度卡片 / 选择卡片（`isSelecting` 二选一，**同位交替**，同尺寸）。
    ///
    /// ⚠️ U13 起这里**只剩这一处内容**：选择模式的「完成」出口搬到了书架分组栏最右边
    /// （`BookshelfView+GroupBar.swift` 的 `groupBar(_:downloadStore:)`）—— 原先那一行
    /// 常驻上栏的「完成」已删除，故这里不再需要承载「选择模式才渲染的行」，
    /// 外面那层只为叠两行而存在的 `VStack(spacing: 0)` 一并去掉（不留空 VStack）。
    private func pinnedHeader(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        Group {
            if viewStore.isSelecting {
                selectionCard(viewStore)
            } else {
                summaryCard(viewStore)
            }
        }
        // ⚠️ 上边距取 `Spacing.xs`(8)：owner 第十轮第 4 条要求「进度卡片的位置与**全部页**默认状态下
        // 第一本书的上边距相同」，而那个值就是书架列表的 `.listRowInsets(top: Spacing.xs)`
        // （见 `BookshelfView.shelfList`）。横向 `Spacing.md`(16) 与书卡的行内边距同源。
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    /// 非选择模式那一支：总进度卡片。
    ///
    /// 单独成函数是为了压 `queueList` 的 `function_body_length`
    /// （SwiftLint warning 50 / error 60，判定严格 `>`）。
    private func summaryCard(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        DownloadSummaryCard(
            progress: viewStore.progress,
            finishedCount: viewStore.finishedCount,
            queuedCount: viewStore.queuedCount,
            failedCount: viewStore.failedCount,
            blockedCount: viewStore.blockedCount,
            isPaused: viewStore.isPaused,
            onTogglePause: {
                viewStore.send(viewStore.isPaused ? .resumeAll : .pauseAll)
            }
        )
    }

    /// 选择模式那一支：四项批量操作卡片（占用总进度卡片那一行）。
    private func selectionCard(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        DownloadSelectionCard(
            selectedBookCount: viewStore.selectedBookPaths.count,
            totalBookCount: viewStore.bookPaths.count,
            isAllSelected: viewStore.areAllBooksSelected,
            pausableBookCount: pausableBookCount(viewStore),
            canPause: viewStore.canPauseSelectedBooks,
            retryableChapterCount: retryableChapterCount(viewStore),
            canRetryFailed: viewStore.canRetryFailedSelectedBooks,
            onToggleSelectAll: {
                viewStore.send(.toggleSelectAllBooks)
            },
            onPause: {
                viewStore.send(.pauseSelectedBooks)
            },
            onDelete: {
                pendingDeletePaths = Array(viewStore.selectedBookPaths)
            },
            onRetryFailed: {
                viewStore.send(.retryFailedSelectedBooks)
            }
        )
    }

    /// 队列级「重试失败项（n）」。
    private func retryFailedRow(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        Button {
            viewStore.send(.retryFailed)
        } label: {
            Label("重试失败项（\(viewStore.failedCount)）", systemImage: "arrow.clockwise")
                // HIG §9：`.frame` 必须落在 label 上才真的撑开命中区（套在 Button 外面无效）。
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .downloadQueueRow()
    }

    /// 队列级「验证后重试（n）」。
    private func retryBlockedRow(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        Button {
            viewStore.send(.retryBlocked)
        } label: {
            Label("验证后重试（\(viewStore.blockedCount)）", systemImage: "checkmark.shield")
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .tint(AppTheme.statusAttention)
        .downloadQueueRow()
    }

    /// 选中书里**会被暂停**的书数。
    ///
    /// 与 reducer 的 `affected`（`pauseSelectedBooks` 分支）同一判据：选中 **且** 有进行中任务。
    /// 只数选中的书会把已完成的书也算进去，卡面数字就与点下去实际发生的事对不上。
    private func pausableBookCount(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> Int {
        let selected = viewStore.selectedBookPaths
        let active = viewStore.tasks.filter { selected.contains($0.bookPath) && $0.state.isActive }
        return Set(active.map(\.bookPath)).count
    }

    /// 选中书里失败的任务数（「重试失败」实际会重排的章节数，单位是章）。
    private func retryableChapterCount(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> Int {
        let selected = viewStore.selectedBookPaths
        return viewStore.tasks.filter { selected.contains($0.bookPath) && $0.state == .failed }.count
    }

    /// 一本书一张卡（**不再渲染逐章任务行**）。
    ///
    /// 单独成函数同样是为了压 `queueList` 的 `function_body_length`。
    ///
    /// ⚠️ 卡上**不再有**「暂停 / 删除」入口（U11 删掉右上角「更多」菜单）：
    /// 这两件事走长按进选择模式后的操作卡片（`selectionCard` 的 `.pauseSelectedBooks`
    /// / `pendingDeletePaths`），所以这里也不再接线。
    private func bookCard(
        _ summary: BookDownloadSummary,
        viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        DownloadBookCard(
            summary: summary,
            isSelecting: viewStore.isSelecting,
            isSelected: viewStore.selectedBookPaths.contains(summary.id),
            onToggleSelection: {
                viewStore.send(.selectionToggled(summary.id))
            },
            onOpenBook: {
                // 书名为 `nil`（书库与快照都没有）时传空串 —— 后果见本视图 `onOpenBook` 属性的说明。
                onOpenBook(summary.id, summary.title ?? "")
            },
            onLongPress: {
                // 再长按一次退出选择模式（与「完成」同一语义：`selectionModeChanged(false)`）。
                viewStore.send(.selectionModeChanged(!viewStore.isSelecting))
            }
        )
        // ⚠️ 只给**行内边距**（8 / 16 / 8 / 16），**不再套 `.downloadQueueCard()`**：
        // 书卡自己的 `cardLabel` 已经画了一层 `Surface.card` 卡面、`content` 也已带 12pt 内边距
        // ⇒ 再套一次就是**第二层卡面 + 第二套 12pt 内边距**（白卡会变成 112、横向 24）。
        // 第十轮第 4 条要求「与书架卡逐值相同」，所以这里只补书架列表那套 `.listRowInsets`。
        .downloadQueueRow()
    }
}

private struct DownloadNoticeRow: View {
    let notice: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(AppTheme.statusAttention)

            Text(notice)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            // §9 按下反馈：`.plain` 按下零反馈；强调层按 12pt 内缩贴图标自身的圆，
            // 不铺成 44pt 大圆盘（命中区仍由 label 的 44×44 + `.contentShape` 提供）。
            .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Circle().inset(by: DesignTokens.Spacing.sm))))
            .accessibilityLabel("关闭提示")
        }
    }
}

/// 下载设置页。
///
/// ⚠️ 可见性是 `internal`（U9-8 起），**不是** `public`：入口已搬到
/// `BookshelfView` 的外层工具栏（仅 `showsLocalGroup` 时出现），
/// 而它就在本模块（`App` target）里，`internal` 已经够用 —— 不要为它加 `public`。
/// 本页仍由 `BookshelfView` 的 `.sheet` 里那层 `NavigationStack` 提供标题与「完成」。
struct DownloadSettingsView: View {
    let store: StoreOf<DownloadFeature>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            Form {
                Section {
                    Toggle(
                        "允许蜂窝网络下载",
                        isOn: Binding(
                            get: { viewStore.allowsCellular },
                            set: { viewStore.send(.setAllowsCellular($0)) }
                        )
                    )

                    Label(
                        viewStore.networkKind.title,
                        systemImage: viewStore.networkKind.icon
                    )
                    .foregroundStyle(.secondary)
                } footer: {
                    Text("关闭时只在 Wi-Fi 下开始新章节；当前请求结束后，队列会等待网络切换。")
                }

                Section {
                    Picker(
                        "下载速度",
                        selection: Binding(
                            get: { viewStore.speed },
                            set: { viewStore.send(.setSpeed($0)) }
                        )
                    ) {
                        Text("保守").tag(DownloadSpeed.conservative)
                        Text("快速").tag(DownloadSpeed.fast)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(speedDescription(for: viewStore.speed))
                }
            }
            .navigationTitle("下载设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func speedDescription(for speed: DownloadSpeed) -> String {
        switch speed {
        case .conservative:
            "保守档每章间隔约 0.75 秒，适合长时间批量下载。"
        case .fast:
            "快速档不设间隔，可能触发网站限制，请谨慎使用。"
        }
    }
}

private extension DownloadNetworkKind {
    var title: String {
        switch self {
        case .unknown:
            "正在检查网络"
        case .offline:
            "当前无网络"
        case .wifi:
            "当前为 Wi-Fi"
        case .cellular:
            "当前为蜂窝网络"
        case .other:
            "当前为其它网络"
        }
    }

    var icon: String {
        switch self {
        case .unknown:
            "network"
        case .offline:
            "wifi.slash"
        case .wifi:
            "wifi"
        case .cellular:
            "antenna.radiowaves.left.and.right"
        case .other:
            "network"
        }
    }
}

#Preview {
    DownloadQueueView(
        store: Store(
            initialState: DownloadFeature.State(
                tasks: [
                    DownloadTaskSnapshot(
                        id: "/1/1/#/1/1/1.html",
                        bookPath: "/1/1/",
                        bookTitle: "示例书",
                        chapterPath: "/1/1/1.html",
                        chapterName: "第一章",
                        chapterNumber: 1,
                        state: .downloading,
                        attempts: 0,
                        lastError: nil,
                        blockedByGuard: false,
                        createdAt: Date(),
                        finishedAt: nil
                    ),
                    DownloadTaskSnapshot(
                        id: "/1/1/#/1/1/2.html",
                        bookPath: "/1/1/",
                        bookTitle: "示例书",
                        chapterPath: "/1/1/2.html",
                        chapterName: "第二章",
                        chapterNumber: 2,
                        state: .queued,
                        attempts: 0,
                        lastError: nil,
                        blockedByGuard: false,
                        createdAt: Date(),
                        finishedAt: nil
                    ),
                ],
                isPaused: false,
                allowsCellular: false,
                speed: .conservative,
                networkKind: .wifi,
                isDownloading: true
            )
        ) {
            DownloadFeature()
        },
        // 预览里不接阅读页：落点在书架那层，这里给一个空实现即可。
        onOpenBook: { _, _ in }
    )
}
