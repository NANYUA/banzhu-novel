import NovelCore
import UIKit

/// 正文 / 章标题的 attributed string 属性 —— **唯一来源**。
///
/// ## 为什么要有这个文件
/// 分页度量（`TextKitMeasuring`）与页面渲染（`App/Sources/ReaderPageTextView.swift`）必须用
/// **逐字段相同**的属性，否则度量盒与渲染盒错位（B0-2 几何契约：每页多塞 / 少塞正文、正文被裁）。
/// 原先两处各写一份 `makeParagraphStyle` + 属性字典，靠注释「改一处必须改另一处」维持；
/// 移植香色闺阁排版参数时属性从 4 项涨到 8 项（字号 / 字重 / 字距 / 行距 / 段距 / 缩进 / 对齐 /
/// 标题分组），两份手抄必然漂 ⇒ 收敛到这里，两边都只剩一次调用。
///
/// ## 参数口径（来自香色闺阁 `plist_paibanKeyInfo.plist` + `PaibanManager.contentAttributes:paibanInfo:`）
/// - `headIndent`：**按字数**的首行缩进（`PaginationConfiguration.firstLineIndentChars`）。
/// - `wordSpacing`：`NSKernAttributeName`（它的 `wordSpacing` 就是字距）。
/// - `lineSpacing` / `paraSpacing`：`NSParagraphStyle.lineSpacing` / `paragraphSpacing`。
/// - `fontWeight`：`NSStrokeWidthAttributeName = -weight`（负值 = 描边与填充同色 ⇒ 视觉加粗）。
/// - 对齐：`setAlignment:3`，即 **`.justified`（两端对齐）** —— 中文正文的标准观感。
/// - 标题：字号 = 正文 + `titleFontSizeOffset`，另有独立的字重 / 字距 / 行距 / 段距。
public enum ReadingTextAttributes {
    /// 正文属性（不含颜色：颜色由 App 层按背景明暗决定）。
    ///
    /// - Parameter firstLineHeadIndent: 本页第一段的首行缩进。整页一律用它；
    ///   「本页从段落中间开始」时调用方传 `0`（续行不该缩进），判据在 `ParagraphBoundary`。
    public static func body(
        configuration: PaginationConfiguration,
        firstLineHeadIndent: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: ReadingFontFactory.makeFont(configuration: configuration),
            .paragraphStyle: paragraphStyle(
                lineSpacing: configuration.lineSpacing,
                paragraphSpacing: configuration.paragraphSpacing,
                firstLineHeadIndent: firstLineHeadIndent
            ),
            .kern: configuration.characterSpacing,
        ]
        if let stroke = strokeWidth(configuration.fontWeight) {
            attributes[.strokeWidth] = stroke
        }
        return attributes
    }

    /// 章标题属性。章标题在正文文本里就是**第一段**（`ReaderFeature.displayText` = 章名 + `"\n\n"` + 正文）。
    ///
    /// 缩进沿用正文那一份（香色闺阁的标题与正文共用 `headIndent`）。
    public static func title(
        configuration: PaginationConfiguration
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: ReadingFontFactory.makeFont(
                configuration: configuration,
                size: configuration.resolvedTitleFontSize
            ),
            .paragraphStyle: paragraphStyle(
                lineSpacing: configuration.resolvedTitleLineSpacing,
                paragraphSpacing: configuration.resolvedTitleParagraphSpacing,
                firstLineHeadIndent: configuration.firstLineHeadIndent
            ),
            .kern: configuration.resolvedTitleCharacterSpacing,
        ]
        if let stroke = strokeWidth(configuration.titleFontWeight) {
            attributes[.strokeWidth] = stroke
        }
        return attributes
    }

    /// 「续行」段落样式：本页从段落中间开始时的第一段用（首行**不缩进**）。
    ///
    /// 为什么单独开一个公开入口而不是把 `paragraphStyle(...)` 整个公开：
    /// 让 App 层只能表达「这一段是续行」这一个意图，拿不到随意拼参数的余地 ——
    /// 否则两端对齐 / 行距 / 段距又会出现第二个构造点。
    public static func continuationParagraphStyle(configuration: PaginationConfiguration) -> NSParagraphStyle {
        paragraphStyle(
            lineSpacing: configuration.lineSpacing,
            paragraphSpacing: configuration.paragraphSpacing,
            firstLineHeadIndent: 0
        )
    }

    /// 段落样式：两端对齐 + 行距 / 段距 / 首行缩进。
    ///
    /// `alignment` 恒为 `.justified`：香色闺阁对正文与标题都设 `setAlignment:3`，
    /// 中文正文不做两端对齐时右边会参差得很明显。
    static func paragraphStyle(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        firstLineHeadIndent: CGFloat
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .justified
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.firstLineHeadIndent = firstLineHeadIndent
        return style
    }

    /// 字重 → `.strokeWidth`（百分数字号宽），`nil` = 不描边（常规）。
    ///
    /// 取值与香色闺阁同域（`-10 … 10`），直接取负：正数 = 更粗，负数 = 更细（向内描边）。
    static func strokeWidth(_ weight: Int) -> NSNumber? {
        guard weight != 0 else { return nil }
        return NSNumber(value: Double(-weight))
    }
}
