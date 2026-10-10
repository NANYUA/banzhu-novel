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
    let onOpenBook: (String) -> Void

    /// 书封面的唯一来源：按 `bookPath` 从书库查（`BookCoverLoader`）。
    @Dependency(\.bookCoverLoader) private var bookCoverLoader

    /// `bookPath → coverUrl`。**不在 `body` 里逐卡查库**：随 `bookPaths` 变化拉一次，
    /// 书卡只做内存查表 —— `List` 滚动时不再读库。
    @State private var coverUrls: [String: String] = [:]

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
            // 封面：队列里的书目变了才拉一次（一次读库；查不到的书回退占位块）。
            .task(id: viewStore.bookPaths) {
                let paths = viewStore.bookPaths
                guard !paths.isEmpty else {
                    coverUrls = [:]
                    return
                }
                coverUrls = await (try? bookCoverLoader.load(paths)) ?? [:]
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

    private func queueList(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        VStack(spacing: 0) {
            if viewStore.isSelecting {
                selectionBar(viewStore)
            }

            List {
                if let notice = viewStore.notice {
                    Section {
                        DownloadNoticeRow(notice: notice) {
                            viewStore.send(.noticeDismissed)
                        }
                        .downloadQueueCard()
                    }
                }

                DownloadSummarySection(
                    progress: viewStore.progress,
                    finishedCount: viewStore.finishedCount,
                    queuedCount: viewStore.queuedCount,
                    failedCount: viewStore.failedCount,
                    blockedCount: viewStore.blockedCount,
                    isPaused: viewStore.isPaused,
                    onTogglePause: {
                        viewStore.send(viewStore.isPaused ? .resumeAll : .pauseAll)
                    },
                    onRetryFailed: {
                        viewStore.send(.retryFailed)
                    },
                    onRetryBlocked: {
                        viewStore.send(.retryBlocked)
                    }
                )

                ForEach(bookSummaries(from: viewStore.tasks, order: viewStore.bookPaths, covers: coverUrls)) { summary in
                    bookCard(summary, viewStore: viewStore)
                }
            }
            .listStyle(.plain)
            // 让 List 自己的滚动背景透出页面分组灰（与书架 `shelfList` 同一手法）。
            .scrollContentBackground(.hidden)
        }
    }

    /// 选择模式下的批量操作栏（本地页自带；位置在分组栏下方、列表上方）。
    ///
    /// 单独成函数是为了压 `queueList` 的 `function_body_length`
    /// （SwiftLint warning 50 / error 60，判定严格 `>`）。
    private func selectionBar(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        DownloadSelectionBar(
            selectedCount: viewStore.selectedBookPaths.count,
            isAllSelected: viewStore.areAllBooksSelected,
            canPause: viewStore.canPauseSelectedBooks,
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
            },
            onDone: {
                viewStore.send(.selectionModeChanged(false))
            }
        )
    }

    /// 一本书一张卡（**不再渲染逐章任务行**）。
    ///
    /// 单独成函数同样是为了压 `queueList` 的 `function_body_length`。
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
                onOpenBook(summary.id)
            },
            onLongPress: {
                // 再长按一次退出选择模式（与「完成」同一语义：`selectionModeChanged(false)`）。
                viewStore.send(.selectionModeChanged(!viewStore.isSelecting))
            },
            onPause: {
                viewStore.send(.pauseBook(summary.id))
            },
            onDelete: {
                pendingDeletePaths = [summary.id]
            }
        )
        .downloadQueueCard()
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

private struct DownloadSummarySection: View {
    let progress: Double
    let finishedCount: Int
    let queuedCount: Int
    let failedCount: Int
    let blockedCount: Int
    let isPaused: Bool
    let onTogglePause: () -> Void
    let onRetryFailed: () -> Void
    let onRetryBlocked: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack {
                    Text("总进度")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .downloadQueueCard()

            Button(action: onTogglePause) {
                Label(
                    isPaused ? "继续全部" : "暂停全部",
                    systemImage: isPaused ? "play.fill" : "pause.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .downloadQueueRow()

            if failedCount > 0 {
                Button(action: onRetryFailed) {
                    Label("重试失败项（\(failedCount)）", systemImage: "arrow.clockwise")
                        // HIG §9：`.frame` 必须落在 label 上才真的撑开命中区（套在 Button 外面无效）。
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .downloadQueueRow()
            }

            if blockedCount > 0 {
                Button(action: onRetryBlocked) {
                    Label("验证后重试（\(blockedCount)）", systemImage: "checkmark.shield")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .tint(AppTheme.statusAttention)
                .downloadQueueRow()
            }
        } header: {
            Text("下载队列")
        }
    }

    private var summaryText: String {
        var parts = ["已完成 \(finishedCount)", "待处理 \(queuedCount)"]
        if failedCount > 0 {
            parts.append("失败 \(failedCount)")
        }
        if blockedCount > 0 {
            parts.append("待验证 \(blockedCount)")
        }
        return parts.joined(separator: " · ")
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
        onOpenBook: { _ in }
    )
}
