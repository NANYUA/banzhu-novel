import ComposableArchitecture
import NovelCore
import SwiftUI

/// 下载管理页：总进度、分书队列、暂停/重试与下载设置。
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
/// **每个「书」= 一个 `Section` = 一张卡**：同一 `Section` 内的章节行共享同一张卡
/// （首行只圆上两角、末行只圆下两角、中间行直角，且上下行内边距为 0 ⇒ 视觉上合并），
/// 而**不是每章一张白卡** —— 书架的隐喻是「一本书一张卡」，
/// 每章一张白卡会让下载页明显偏重、与"融入书架"相反。
struct DownloadQueueView: View {
    let store: StoreOf<DownloadFeature>

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
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无下载",
            systemImage: "arrow.down.circle",
            description: Text("可在书籍目录中下载单章或整本。")
        )
    }

    private func queueList(
        _ viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
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

            ForEach(bookSections(from: viewStore.tasks)) { section in
                bookSection(section, viewStore: viewStore)
            }
        }
        .listStyle(.plain)
        // 让 List 自己的滚动背景透出页面分组灰（与书架 `shelfList` 同一手法）。
        .scrollContentBackground(.hidden)
    }

    /// 一本书 = 一个 `Section` = 一张卡（章节行合并；header 自成一张卡压在它上面）。
    ///
    /// 单独成函数是为了压 `queueList` 的 `function_body_length`
    /// （SwiftLint warning 50 / error 60，判定严格 `>`）。
    private func bookSection(
        _ section: BookDownloadSection,
        viewStore: ViewStore<DownloadFeature.State, DownloadFeature.Action>
    ) -> some View {
        Section {
            ForEach(section.tasks.indices, id: \.self) { index in
                DownloadTaskRow(task: section.tasks[index])
                    .downloadQueueCard(
                        topRounded: index == 0,
                        bottomRounded: index == section.tasks.count - 1
                    )
            }
        } header: {
            DownloadBookHeader(section: section) {
                viewStore.send(.pauseBook(section.id))
            } onCancel: {
                viewStore.send(.cancelBook(section.id))
            }
            .downloadQueueSectionHeaderCard()
        }
    }
}

// MARK: - U9-8 卡片装饰（与书架同源）

private extension View {
    /// 不成卡的行（系统控件 / 提示条）：清行底 + 隐藏分隔线 + 书架同款左右 16pt 页边距。
    func downloadQueueRow(
        top: CGFloat = DesignTokens.Spacing.xs,
        bottom: CGFloat = DesignTokens.Spacing.xs
    ) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(
                .init(
                    top: top,
                    leading: DesignTokens.Spacing.md,
                    bottom: bottom,
                    trailing: DesignTokens.Spacing.md
                )
            )
    }

    /// 卡面（`Surface.card` + `Radius.sm`），圆角按「是不是 Section 的首 / 末行」取舍。
    ///
    /// 上下行内边距取 0 ⇒ 同一 `Section` 内相邻章节行的卡面直接相接，合并成一张卡；
    /// 只有首行圆上两角、末行圆下两角，中间行走直角
    /// （`UnevenRoundedRectangle` 支持逐角指定，iOS 17 起可用）。
    func downloadQueueCard(
        topRounded: Bool = true,
        bottomRounded: Bool = true
    ) -> some View {
        padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                AppTheme.Surface.card,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: topRounded ? DesignTokens.Radius.sm : 0,
                    bottomLeadingRadius: bottomRounded ? DesignTokens.Radius.sm : 0,
                    bottomTrailingRadius: bottomRounded ? DesignTokens.Radius.sm : 0,
                    topTrailingRadius: topRounded ? DesignTokens.Radius.sm : 0
                )
            )
            .downloadQueueRow(top: 0, bottom: 0)
    }

    /// 每本书的 header 自成一张卡（四角全圆），压在它自己那张章节行卡之上。
    func downloadQueueSectionHeaderCard() -> some View {
        padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                AppTheme.Surface.card,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            )
            .downloadQueueRow(top: 0, bottom: DesignTokens.Spacing.xs)
    }
}

private struct DownloadNoticeRow: View {
    let notice: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)

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

private struct DownloadBookHeader: View {
    let section: BookDownloadSection
    let onPause: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(section.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(section.finishedCount)/\(section.tasks.count) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button(action: onPause) {
                    Label("暂停本书", systemImage: "pause")
                }
                Button(role: .destructive, action: onCancel) {
                    Label("取消本书下载", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("本书下载操作")
        }
        .textCase(nil)
    }
}

private struct DownloadTaskRow: View {
    let task: DownloadTaskSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: statusIcon)
                .font(.body)
                .foregroundStyle(statusColor)
                .frame(minWidth: 22)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("\(task.chapterNumber). \(task.chapterName)")
                    .font(.body)
                    .lineLimit(1)

                Text(statusTitle)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                if let message = task.lastError, task.state == .failed || task.blockedByGuard {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private var statusTitle: String {
        switch task.state {
        case .queued:
            "等待下载"
        case .downloading:
            "下载中"
        case .paused:
            task.blockedByGuard ? "需要验证" : "已暂停"
        case .done:
            "已下载"
        case .failed:
            "下载失败"
        }
    }

    private var statusIcon: String {
        switch task.state {
        case .queued:
            "clock"
        case .downloading:
            "arrow.down.circle.fill"
        case .paused:
            task.blockedByGuard ? "shield.lefthalf.filled" : "pause.circle"
        case .done:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.circle.fill"
        }
    }

    /// 状态色统一（§4 / §17）：进行中 = 强调色，已完成 = 系统绿，失败 = 系统红。
    private var statusColor: Color {
        switch task.state {
        case .queued:
            .secondary
        case .downloading:
            AppTheme.accent
        case .done:
            .green
        case .paused:
            task.blockedByGuard ? .orange : .secondary
        case .failed:
            .red
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

private struct BookDownloadSection: Identifiable {
    let id: String
    let title: String
    let tasks: [DownloadTaskSnapshot]

    var finishedCount: Int {
        tasks.filter { $0.state == .done }.count
    }
}

private func bookSections(from tasks: [DownloadTaskSnapshot]) -> [BookDownloadSection] {
    var order: [String] = []
    var grouped: [String: [DownloadTaskSnapshot]] = [:]

    for task in tasks {
        if grouped[task.bookPath] == nil {
            order.append(task.bookPath)
        }
        grouped[task.bookPath, default: []].append(task)
    }

    return order.compactMap { bookPath in
        guard let bookTasks = grouped[bookPath], let first = bookTasks.first else {
            return nil
        }
        return BookDownloadSection(
            id: bookPath,
            title: first.bookTitle,
            tasks: bookTasks
        )
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
        }
    )
}
