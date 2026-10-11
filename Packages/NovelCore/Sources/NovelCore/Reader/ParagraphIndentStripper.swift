import Foundation

/// 删掉**每一行开头**的空白字符（行首缩进），其余原样保留。
///
/// ## 为什么需要它（owner 真机反馈）
/// 「正文不开首行缩进，所有段落都会默认缩进一格」—— 那一格**不是我们画的**：
/// 中文站点的正文 HTML 里每段开头本来就带空白（全角空格 `U+3000` / 普通空格），
/// 旧的 `displayText` 只对**整段文字的首尾**做 `trimmingCharacters`，
/// 行首空白原样进了 `displayText` ⇒ 缩进开关关掉后仍然看得见缩进。
///
/// ## 口径（owner 已拍板）：**总是删**，与缩进开关无关
/// 不论「首行缩进」开着还是关着，都先把行首空白删掉 ⇒ 缩进宽度**完全由设置决定**：
/// 开关开 = `NSParagraphStyle.firstLineHeadIndent`（2 个字），开关关 = 0。
/// ⛔ 不要做成「只在关掉时删」—— 那会让同一个位置在两种设置下差若干字符，
/// 分页与已存偏移的漂移量随设置变化。
///
/// ## 为什么放在 NovelCore 的纯函数里
/// 归一化发生在正文**进入渲染与分页之前**（`ReaderFeature.State.displayText`），
/// 而分页在 CI 上要能测（`Paginator` 是纯 Swift 的）。逻辑落在这里，
/// 不需要真机、不需要 UIKit 就能被 `swift test` 覆盖。
///
/// ## 与 `ParagraphBoundary` 的分工（别把这两件事混了）
/// - 本类型管**文本里有没有多余空白**（内容问题，在分页之前一次性做掉）；
/// - `ParagraphBoundary` 管**这一段该不该画缩进**（排版问题，度量侧与渲染侧共用）。
/// 两者都在 NovelCore，就是为了让「内容归一化」与「排版判据」都不依赖 UIKit。
public enum ParagraphIndentStripper {
    /// 要删的行首字符（**只删行首连续的这几个**，行内与行尾一律不碰）。
    ///
    /// 只列实际会出现的那三个，不用 `.whitespaces` 整集合：中文站点正文里
    /// 行首除了半角空格与制表符，就只有全角空格 `U+3000`；
    /// 收窄到白名单可以保证**永远不会**误删别的字符（宁可漏删，不可错删）。
    /// - 半角空格 `U+0020`
    /// - 制表符 `U+0009`
    /// - 全角空格 `U+3000`（中文站点每段开头缩进一格用的就是它）
    private static let leadingIndent: Set<Character> = [" ", "\t", "\u{3000}"]

    /// 删掉 `text` 里每一行开头的连续空白字符。
    ///
    /// ## 逐条口径
    /// - 只处理**行首**连续空白：`"  abc def"` → `"abc def"`（行内那个空格原样保留）；
    /// - 连续多个一起删：`"\u{3000}\u{3000}abc"` → `"abc"`；
    /// - **不动换行本身**：换行是「行」的分隔符，既不会被删，也不会被合并
    ///   ⇒ 空行（连续换行）原样保留；
    /// - **不动行尾空白**：行尾空白由调用方（`displayText` 里的 `trimmingCharacters`）负责。
    ///
    /// ## 实现：逐字符扫一遍，只在「行首状态」里丢字符
    /// 不按 `components(separatedBy: "\n")` 切分再拼回去 —— 那样要额外处理
    /// `\r\n`（Swift 里它是**一个** Character）、以及空串切分出的 `[""]`。
    /// 逐字符扫描天然避开这两个坑：换行只用来翻转「行首」标志，原文一个字节都不动。
    ///
    /// - Parameter text: 原始正文（或已拼好标题的显示文本）。
    /// - Returns: 每行都去掉行首空白的文本。空串 / 全是空白 / 全是换行都不会崩。
    public static func strippingLineIndents(in text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var isAtLineStart = true
        for character in text {
            if isAtLineStart, leadingIndent.contains(character) {
                continue // 行首空白：丢掉，且**保持在行首状态**（连续多个一起删）
            }
            result.append(character)
            isAtLineStart = character.isNewline
        }
        return result
    }
}
