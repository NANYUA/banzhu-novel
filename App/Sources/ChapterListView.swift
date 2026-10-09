import NovelCore
import SwiftUI

/// 目录区块 —— **直接内嵌在书籍详情页里**（U1-6）。
///
/// ## 为什么不是 `List`
/// 详情页外层是 `ScrollView`，而 `List` 需要自己的滚动上下文：
/// 把 `List` 塞进 `ScrollView` 会让它的高度塌掉。所以这里把章节渲染成普通内容，
/// 用 `LazyVStack` 只做懒布局（章节多时首屏只渲染前若干条，其余就地展开），
/// 也不再 push 单独的目录页。
///
/// ## 下载（U1-7）
/// - 每行右侧是**单章**下载按钮（已下载则置灰）；
/// - 区块头部给一句「已下载 N 章」，并给「下载章节…」入口；
/// - 入口点开的是多选面板 `ChapterDownloadPicker`（全选 / 多选，已下载的不可勾选）。
struct ChapterListView: View {
    let data: ChapterDirectoryData
    let onToggleShowAll: () -> Void
    let onRetry: () -> Void
    let onSelect: (ChapterItem) -> Void
    let onDownloadChapter: (ChapterItem) -> Void
    let onDownloadRequested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header

            if data.isLoading, data.visibleChapters.isEmpty {
                ProgressView("目录加载中…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignTokens.Spacing.lg)
            } else if let message = data.errorMessage, data.visibleChapters.isEmpty {
                errorState(message)
            } else if data.visibleChapters.isEmpty {
                emptyState
            } else {
                chapterRows
                showAllButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 区块内容

private extension ChapterListView {
    var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text("目录")
                    .font(.headline)

                Spacer(minLength: DesignTokens.Spacing.xs)

                Button {
                    onDownloadRequested()
                } label: {
                    Label("下载章节…", systemImage: "arrow.down.circle")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .disabled(data.totalCount == 0)
                .accessibilityLabel("下载章节，选择要下载的章节")
            }

            // U1-7：入口就给「已下载 N 章」，点进去之前就知道这本下过多少。
            Text("共 \(data.totalCount) 章 · 已下载 \(data.downloadedCount) 章")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var chapterRows: some View {
        LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(data.visibleChapters) { chapter in
                row(chapter)
            }
        }
    }

    /// 一行目录：整块是可点区域（进阅读页），右侧是单章下载按钮。
    ///
    /// 刻意不用 `NavigationLink`：在普通容器里它没有可感知的按下反馈，
    /// 而本项目的硬约束是「按下必须有反馈」—— 用 `Button` + `PressableCardButtonStyle`。
    func row(_ chapter: ChapterItem) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button {
                onSelect(chapter)
            } label: {
                rowLabel(chapter)
            }
            .buttonStyle(PressableCardButtonStyle(
                pressedScale: 0.99,
                shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
            ))

            downloadButton(chapter)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .background(
            AppTheme.Surface.card,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        )
    }

    func rowLabel(_ chapter: ChapterItem) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("\(chapter.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)

            Text(chapter.name)
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: DesignTokens.Spacing.xs)

            statusBadge(chapter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    func downloadButton(_ chapter: ChapterItem) -> some View {
        Button {
            onDownloadChapter(chapter)
        } label: {
            Image(systemName: chapter.isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(chapter.isDownloaded ? Color.green : AppTheme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(chapter.isDownloaded)
        .accessibilityLabel(chapter.isDownloaded ? "已下载" : "下载本章")
    }

    /// 本地状态标记。判定一律走 `ChapterItem.isDownloaded`（`ChapterRecord.source`）。
    @ViewBuilder
    func statusBadge(_ chapter: ChapterItem) -> some View {
        if chapter.isDownloaded {
            // 状态色统一：已下载与已缓存正文都属「已完成」→ 系统绿。
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("已下载")
        } else if chapter.hasLocalText {
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("已缓存正文")
        }
    }

    @ViewBuilder
    var showAllButton: some View {
        if data.hasHiddenChapters || data.isShowingAll {
            Button {
                onToggleShowAll()
            } label: {
                Label(
                    data.isShowingAll ? "收起目录" : "查看全部目录（共 \(data.totalCount) 章）",
                    systemImage: data.isShowingAll ? "chevron.up" : "chevron.down"
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
        }
    }

    var emptyState: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "list.bullet")
                .foregroundStyle(.secondary)
            Text("本地目录快照里还没有章节，可稍后重试。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            AppTheme.Surface.card,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        )
    }

    func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("目录加载失败", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("重试") {
                onRetry()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(
            AppTheme.Surface.card,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        )
    }
}

/// 内嵌目录区块的只读数据（由 `BookDetailFeature.State` 派生，视图只读值、不碰 reducer）。
struct ChapterDirectoryData {
    /// 当前实际渲染的章节（可能只是前若干条）。
    var visibleChapters: [ChapterItem]
    /// 整本目录的章节总数。
    var totalCount: Int
    /// 已下载的章节数。
    var downloadedCount: Int
    /// 还有没有没渲染出来的章节。
    var hasHiddenChapters: Bool
    /// 是否已展开全部章节。
    var isShowingAll: Bool
    /// 目录是否加载中。
    var isLoading: Bool
    /// 目录加载失败原因。
    var errorMessage: String?
}

/// 章节下载选择面板（U1-7）。
///
/// - 多选 + 全选（全选只勾**未下载**的章节）；
/// - 已下载的章节明确标「已下载」且置灰不可选 —— 判定走 `ChapterItem.isDownloaded`，
///   也就是 `ChapterRecord.source == .downloaded`，不绕过 source 标记自己猜；
/// - 顶部给一句「已下载 N 章」，底部常驻「下载选中的 K 章」。
///
/// 这里用 `List` 是安全的：它长在 sheet 自己的滚动上下文里，没有嵌进详情页的 `ScrollView`。
struct ChapterDownloadPicker: View {
    let chapters: [ChapterItem]
    let onConfirm: ([ChapterItem]) -> Void

    @State private var selectedPaths: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chapters) { chapter in
                        row(chapter)
                    }
                } header: {
                    Text("已下载 \(downloadedCount) 章，共 \(chapters.count) 章")
                } footer: {
                    Text("已下载的章节永久保留，不会被缓存淘汰；勾选的章节会按章号顺序逐章下载。")
                }

                if chapters.isEmpty {
                    Text("本地目录快照里还没有章节。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("选择章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isAllDownloadableSelected ? "取消全选" : "全选") {
                        toggleSelectAll()
                    }
                    .disabled(downloadableChapters.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                confirmBar
            }
        }
    }
}

private extension ChapterDownloadPicker {
    var downloadedCount: Int {
        chapters.filter(\.isDownloaded).count
    }

    /// 可勾选的章节：已下载的**不参与**（它们既不用再下、也不该被取消）。
    var downloadableChapters: [ChapterItem] {
        chapters.filter { !$0.isDownloaded }
    }

    var selectedChapters: [ChapterItem] {
        chapters.filter { selectedPaths.contains($0.path) }
    }

    var isAllDownloadableSelected: Bool {
        !downloadableChapters.isEmpty
            && downloadableChapters.allSatisfy { selectedPaths.contains($0.path) }
    }

    var confirmBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                onConfirm(selectedChapters)
            } label: {
                Text(selectedChapters.isEmpty ? "请选择章节" : "下载选中的 \(selectedChapters.count) 章")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedChapters.isEmpty)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .background(.regularMaterial)
    }

    func row(_ chapter: ChapterItem) -> some View {
        Button {
            toggle(chapter)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: selectionIcon(chapter))
                    .font(.title3)
                    .foregroundStyle(chapter.isDownloaded ? Color.secondary : AppTheme.accent)

                Text("\(chapter.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)

                Text(chapter.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(chapter.isDownloaded ? Color.secondary : Color.primary)

                Spacer(minLength: DesignTokens.Spacing.xs)

                if chapter.isDownloaded {
                    // 明确标注「已下载」，而不是只靠一个图标让用户猜。
                    Text("已下载")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardButtonStyle(pressedScale: 0.99))
        .disabled(chapter.isDownloaded)
        .accessibilityLabel(rowAccessibilityLabel(for: chapter))
    }

    func selectionIcon(_ chapter: ChapterItem) -> String {
        if chapter.isDownloaded {
            return "checkmark.circle.fill"
        }
        return selectedPaths.contains(chapter.path) ? "checkmark.circle.fill" : "circle"
    }

    func rowAccessibilityLabel(for chapter: ChapterItem) -> String {
        if chapter.isDownloaded {
            return "\(chapter.name)，已下载，不可重复选择"
        }
        return "\(chapter.name)，\(selectedPaths.contains(chapter.path) ? "已选中" : "未选中")"
    }

    func toggle(_ chapter: ChapterItem) {
        // 已下载的章节不可勾选（UI 已置灰禁用，这里再挡一道，行为不依赖 UI 层）。
        guard !chapter.isDownloaded else { return }
        if selectedPaths.contains(chapter.path) {
            selectedPaths.remove(chapter.path)
        } else {
            selectedPaths.insert(chapter.path)
        }
    }

    func toggleSelectAll() {
        if isAllDownloadableSelected {
            selectedPaths.removeAll()
        } else {
            selectedPaths = Set(downloadableChapters.map(\.path))
        }
    }
}

/// 章节 → 入队请求。字段映射只写一处，目录行、选择面板、详情页主按钮共用。
extension DownloadChapterRequest {
    init(chapter: ChapterItem, bookPath: String, bookTitle: String) {
        self.init(
            bookPath: bookPath,
            bookTitle: bookTitle,
            chapterPath: chapter.path,
            chapterName: chapter.name,
            chapterNumber: chapter.number
        )
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        ChapterListView(
            data: ChapterDirectoryData(
                visibleChapters: [
                    ChapterItem(number: 1, name: "第一章 夜探皇宫", path: "/1/1/1.html", hasLocalText: true, isDownloaded: false),
                    ChapterItem(number: 2, name: "第二章 风云起", path: "/1/1/2.html", hasLocalText: true, isDownloaded: true),
                    ChapterItem(number: 3, name: "第三章 长街", path: "/1/1/3.html", hasLocalText: false, isDownloaded: false),
                ],
                totalCount: 120,
                downloadedCount: 1,
                hasHiddenChapters: true,
                isShowingAll: false,
                isLoading: false,
                errorMessage: nil
            ),
            onToggleShowAll: {},
            onRetry: {},
            onSelect: { _ in },
            onDownloadChapter: { _ in },
            onDownloadRequested: {}
        )
        .padding(DesignTokens.Spacing.md)
    }
    .background(AppTheme.Surface.page)
}

#Preview("选择章节") {
    ChapterDownloadPicker(
        chapters: [
            ChapterItem(number: 1, name: "第一章 夜探皇宫", path: "/1/1/1.html", hasLocalText: true, isDownloaded: false),
            ChapterItem(number: 2, name: "第二章 风云起", path: "/1/1/2.html", hasLocalText: true, isDownloaded: true),
            ChapterItem(number: 3, name: "第三章 长街", path: "/1/1/3.html", hasLocalText: false, isDownloaded: false),
        ],
        onConfirm: { _ in }
    )
}
