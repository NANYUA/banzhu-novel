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
/// - 区块头部只给一句「共 N 章 · 已下载 M 章」；
/// - 多章 / 整本下载的入口**不在这里**：U1-8 起它在详情页按钮组
///   （`BookDetailView+Actions.swift` 的「下载章节」），同页不再摆第二个相同入口。
///   面板本身仍是 `ChapterDownloadPicker`（全选 / 多选，已下载的不可勾选）。
struct ChapterListView: View {
    let data: ChapterDirectoryData
    let onToggleShowAll: () -> Void
    let onRetry: () -> Void
    let onSelect: (ChapterItem) -> Void
    let onDownloadChapter: (ChapterItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header

            // 加载失败**无条件**在区块顶部插一条错误条：已经有旧目录时重试失败也必须说话，
            // 否则用户点了重试却看不出任何变化（旧数据照旧显示，不替换列表）。
            if let message = data.errorMessage {
                InlineErrorBanner(
                    title: "目录加载失败",
                    message: message,
                    onRetry: onRetry
                )
            }

            if data.visibleChapters.isEmpty {
                // 没数据可显示时才轮到「加载中 / 空态」占位；失败原因已由上面的错误条给出，
                // 不再叠一张空态卡说第二遍。
                if data.isLoading {
                    ProgressView("目录加载中…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.lg)
                } else if data.errorMessage == nil {
                    emptyState
                }
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
            // 标题右侧原先摆着「下载章节…」按钮（U1-8 移到详情页按钮组），
            // 那个只为把它推到右边而存在的 `HStack` + `Spacer` 已一并清掉。
            Text("目录")
                .font(.headline)

            // U1-7：入口就给「已下载 N 章」，点进去之前就知道这本下过多少。
            // 措辞与选择面板 header 保持一致（同一口径、同一句式）。
            if data.totalCount > 0 {
                Text("共 \(data.totalCount) 章 · 已下载 \(data.downloadedCount) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    /// 单章下载按钮。
    ///
    /// 与左侧整行同一套按下反馈（可见强调层）：原来用 `.borderless` 只有系统级 dim，
    /// 同一行里两种反馈量级不一致，点右边几乎看不出按下了。
    /// 圆形强调层贴合图标本身的轮廓。
    func downloadButton(_ chapter: ChapterItem) -> some View {
        Button {
            onDownloadChapter(chapter)
        } label: {
            Image(systemName: chapter.isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(chapter.isDownloaded ? AppTheme.statusAdded : AppTheme.accent)
                // 用 min 而不是固定值：`.font(.title3)` 会随 Dynamic Type 放大，写死会裁掉图标。
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardButtonStyle(pressedScale: 0.94, shape: AnyShape(Circle())))
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
                .foregroundStyle(AppTheme.statusAdded)
                .accessibilityLabel("已下载")
        } else if chapter.hasLocalText {
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(AppTheme.statusAdded)
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
/// - 顶部给一句「共 N 章 · 已下载 M 章」，底部常驻「下载选中的 K 章」。
///
/// 勾选逻辑（谁可被勾、全选选谁）全部在 `ChapterDownloadSelection` 这个值类型里，
/// 本视图只渲染它、并把结果回传给 `onConfirm`。
/// 「已下载 / 可下载」两个计数由 `BookDetailFeature.State` 派生后**作为入参**传进来，
/// 面板不再自己 `filter().count` —— 同一口径只有一处。
///
/// 这里用 `List` 是安全的：它长在 sheet 自己的滚动上下文里，没有嵌进详情页的 `ScrollView`。
struct ChapterDownloadPicker: View {
    let chapters: [ChapterItem]
    /// 已下载章节数（目录 header 同源）。
    let downloadedCount: Int
    /// 可勾选（未下载）章节数，决定「全选」是否可用。
    let downloadableCount: Int
    let onConfirm: ([ChapterItem]) -> Void

    @State private var selection = ChapterDownloadSelection()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chapters) { chapter in
                        row(chapter)
                    }
                } header: {
                    Text("共 \(chapters.count) 章 · 已下载 \(downloadedCount) 章")
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
                    Button(selection.isAllSelected(in: chapters) ? "取消全选" : "全选") {
                        selection.toggleSelectAll(in: chapters)
                    }
                    .disabled(downloadableCount == 0)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                confirmBar
            }
        }
    }
}

private extension ChapterDownloadPicker {
    var selectedChapters: [ChapterItem] {
        selection.selectedChapters(in: chapters)
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
            selection.toggle(chapter)
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
                        .foregroundStyle(AppTheme.statusAdded)
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
        return selection.isSelected(chapter) ? "checkmark.circle.fill" : "circle"
    }

    func rowAccessibilityLabel(for chapter: ChapterItem) -> String {
        if chapter.isDownloaded {
            return "\(chapter.name)，已下载，不可重复选择"
        }
        return "\(chapter.name)，\(selection.isSelected(chapter) ? "已选中" : "未选中")"
    }
}

/// 页内 inline 错误条：详情读库失败与目录加载失败**共用同一套**视觉与「重试」入口。
///
/// 它插在区块顶部、**不替换**已有内容：已经有旧数据时重试失败，用户同样要能看到原因，
/// 否则「点了重试没反应」和「没点」看起来一样。
struct InlineErrorBanner: View {
    let title: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // `.controlSize(.large)` 保证「重试」是 44pt 触控目标。
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
            onDownloadChapter: { _ in }
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
        downloadedCount: 1,
        downloadableCount: 2,
        onConfirm: { _ in }
    )
}
