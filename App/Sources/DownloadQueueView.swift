import ComposableArchitecture
import NovelCore
import SwiftUI

/// 下载管理页：总进度、分书队列、暂停/重试与下载设置。
struct DownloadQueueView: View {
    let store: StoreOf<DownloadFeature>

    @State private var isShowingSettings = false

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
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
                .navigationTitle("下载")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Label("下载设置", systemImage: "gearshape")
                        }
                    }
                }
                .onAppear {
                    viewStore.send(.task)
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    DownloadSettingsView(store: store)
                }
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
                Section {
                    ForEach(section.tasks) { task in
                        DownloadTaskRow(task: task)
                    }
                } header: {
                    DownloadBookHeader(section: section) {
                        viewStore.send(.pauseBook(section.id))
                    } onCancel: {
                        viewStore.send(.cancelBook(section.id))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
            .buttonStyle(.plain)
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

            Button(action: onTogglePause) {
                Label(
                    isPaused ? "继续全部" : "暂停全部",
                    systemImage: isPaused ? "play.fill" : "pause.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if failedCount > 0 {
                Button(action: onRetryFailed) {
                    Label("重试失败项（\(failedCount)）", systemImage: "arrow.clockwise")
                        // HIG §9：`.frame` 必须落在 label 上才真的撑开命中区（套在 Button 外面无效）。
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }

            if blockedCount > 0 {
                Button(action: onRetryBlocked) {
                    Label("验证后重试（\(blockedCount)）", systemImage: "checkmark.shield")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .tint(.orange)
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
        HStack(alignment: .center, spacing: 12) {
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.body)
                .foregroundStyle(statusColor)
                .frame(minWidth: 22)

            VStack(alignment: .leading, spacing: 4) {
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

private struct DownloadSettingsView: View {
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
