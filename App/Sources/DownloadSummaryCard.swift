// `.formatted(_:)`（`progress` 的百分比格式化）来自 Foundation 的 FormatStyle，
// 单独成文件后不再由原文件的其它 import 顺带带进来 —— 显式声明依赖。
import Foundation
import SwiftUI

/// 总进度卡片（**非选择模式**那一支；选择模式那一支是 `DownloadSelectionCard`）。
///
/// ## 两列化（U11）
/// owner 口径：「将暂停全部按钮放到总进度卡片右边进度百分比下，进度条最大值左移」。
/// 左列 = 标题 / 进度条 / 完成与待处理；右列 = 固定宽度（`DownloadCardMetrics.progressColumnWidth`）
/// 的百分比 + 「暂停全部」。右列占宽 ⇒ **进度条右端自然左移缩短**，给右侧按钮让位。
/// 「暂停全部」原先在卡片下面单独占一整行（`.borderedProminent` + `.controlSize(.large)`），
/// 现搬进右列、紧跟百分比下方。
///
/// ## 尺寸与书卡对齐
/// 内容区 `DownloadCardMetrics.contentHeight`(80) + `.downloadQueueCard()` **自带**的内边距
/// `Spacing.sm`(12) × 2 ⇒ 白卡 **104pt**，与书架 `BookRow`、下载页书卡、选择卡片同高。
/// ⚠️ 那套 12pt 由 `.downloadQueueCard()` **独家**提供，这里（以及选择卡片）都**不再自己加**
/// —— 再叠一层就是白卡 128（第十轮第 4 条：与书架卡逐值相同）。
/// 注：书卡不走 `.downloadQueueCard()`（它自己画了卡面），只调 `.downloadQueueRow()`。
///
/// ⚠️ 它**不再是 `List` 里的 `Section` 行**：卡片被搬出 `List`、与 `List` **并列常驻上栏**，
/// 由 `DownloadQueueView.pinnedHeader` 渲染 —— 与选择模式的 `DownloadSelectionCard`
/// **同位交替**（`if isSelecting { 选择卡 } else { 本卡 }`）。
/// 选择模式的「完成」出口**已不在下载页**：它搬到了书架分组栏最右边
/// （`BookshelfView+GroupBar.swift` 的 `groupBar(_:downloadStore:)` 里的 `selectionDoneChip`）。
///
/// ⚠️ 单独成文件（U11 收尾）：`DownloadQueueView.swift` 当时已到 **595/600 行**
/// （SwiftLint `file_length` warning 600，CI `--strict` 下 warning 即失败），
/// 只差 5 行余量。本卡片与那个文件里剩下的东西没有耦合（它只依赖 `DesignTokens` /
/// `AppTheme` / `DownloadCardMetrics` 与 `.downloadQueueCard()`），整段搬出来
/// **一行内容都没改**，只把 `private struct` / `private extension` 放开成模块内可见。
struct DownloadSummaryCard: View {
    let progress: Double
    let finishedCount: Int
    let queuedCount: Int
    let failedCount: Int
    let blockedCount: Int
    let isPaused: Bool
    let onTogglePause: () -> Void

    /// 右列宽度随 Dynamic Type 缩放（基础值见 `DownloadCardMetrics.progressColumnWidth`）：
    /// 定死 106 的话，超大字号下「暂停全部」会被挤到截断。
    @ScaledMetric(relativeTo: .subheadline) private var progressColumnWidth = DownloadCardMetrics.progressColumnWidth

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("总进度")
                    .font(.footnote.weight(.semibold))

                ProgressView(value: progress)

                Text(summaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                pauseButton
            }
            .frame(width: progressColumnWidth)
        }
        .frame(minHeight: DownloadCardMetrics.contentHeight)
        // ⚠️ 这里**不再自己加 12pt 内边距**：`.downloadQueueCard()` 已经带了一套
        // `Spacing.sm`（见 `DownloadBookCard.swift` 里该修饰器的文档块）。
        // 第十轮第 4 条要求「与书架卡逐值相同」，而书架卡只有**一层** 12pt
        // ⇒ 自己再加一层会让白卡变成 128（104 + 24），与书卡对不齐。
        .downloadQueueCard()
    }
}

extension DownloadSummaryCard {
    /// 「暂停全部 / 继续全部」。
    ///
    /// 原先那行大按钮用 `.controlSize(.large)`；搬进固定宽的右列后必须去掉 ——
    /// `.large` 自身左右内边距会把标签挤到截断（命中区仍由 label 上的 `minHeight: 44` 保证）。
    var pauseButton: some View {
        Button(action: onTogglePause) {
            Label(
                isPaused ? "继续全部" : "暂停全部",
                systemImage: isPaused ? "play.fill" : "pause.fill"
            )
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            // HIG §9：`.frame` 必须落在 label 上才真的撑开命中区（套在 Button 外面无效）。
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
    }

    var summaryText: String {
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
