import Foundation

/// UTF-16 长度 ↔ Character 个数的换算。
///
/// ## 为什么需要它（H1）
/// `NSLayoutManager.characterRange(forGlyphRange:)` 报的是 **UTF-16 码元**数，
/// 而 `Paginator` 的游标是 **Character**：它用 `Array(text)` 切分，守恒律写成
/// `sum(pages.length) == text.count`（`text.count` 是 Character 个数）。
///
/// 两者在纯 CJK / ASCII 下**恰好相等**，所以这个错配长期没有暴露；
/// 一旦正文出现 emoji、代理对生僻字或组合字符，度量报的长度就会**大于**
/// 实际能放下的字符数，于是每页被多塞进若干字符 —— 恰好违反上面那条守恒律。
///
/// 换算集中放在这里（而不是散在 `TextKitMeasuring` 里），是为了让这段逻辑
/// 落在 NovelCore 这个**纯 Swift、CI 可测**的包里：`TextKitMeasuring` 依赖
/// UIKit，在 macOS host 上根本不参与 `swift test`。
public enum TextCursor {
    /// `text` 的前 `utf16Length` 个 UTF-16 码元，覆盖了 **多少个 Character**。
    ///
    /// 边界落在字素簇内部时**向前取整**：宁可少放一个字符，也不切出半个
    /// （例如只取到 emoji 代理对的前一半、或组合字符 `e` + `U+0301` 只取到 `e`）。
    ///
    /// - Parameters:
    ///   - utf16Length: UTF-16 码元个数；越界与负数都会被夹到 `0...text.utf16.count`。
    ///   - text: 待换算的字符串。
    /// - Returns: 前缀覆盖的 Character 个数，范围 `0...text.count`。
    public static func characterCount(ofUTF16Length utf16Length: Int, in text: String) -> Int {
        let limit = min(max(utf16Length, 0), text.utf16.count)

        var consumed = 0
        var count = 0
        for character in text {
            // 一个 Character（字素簇）可能由多个 scalar 组成，每个 scalar 占 1 或 2 个码元。
            let width = character.unicodeScalars.reduce(0) { $0 + UTF16.width($1) }
            if consumed + width > limit {
                break
            }
            consumed += width
            count += 1
        }
        return count
    }
}
