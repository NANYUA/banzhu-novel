import Foundation

/// 段落边界判定：一页的第一行要不要加首行缩进，**只有这一条判据**。
///
/// ## 为什么需要它
/// `firstLineHeadIndent` 是**段落属性**（`NSParagraphStyle` 上的一项），只作用于每个段落的
/// **第一行**。而分页把整章切成一段段字符切片，一页的切片很可能**从段落中间开始** ——
/// 这时切片开头那个「段落」其实是**半截段落**，它的第一行是**续行**，不该有缩进。
/// 不加区分地给整页套上 `firstLineHeadIndent`，观感上就像「每一页都从新段落开始」。
///
/// ## 为什么放在 NovelCore
/// 度量侧（`Packages/NovelPagination/.../TextKitMeasuring.swift`）与渲染侧
/// （`App/Sources/ReaderPageTextView.swift`）各自独立构建 `NSAttributedString`，
/// 两边**必须用同一条判据、逐值一致**；否则度量盒与实际渲染盒错位（每页多塞 / 少塞正文，
/// 正文被裁，见 B0-2 几何契约）。判据放在纯 Swift、CI 可测的 NovelCore 里，
/// 两侧都只能调它，**不允许各自再写一份**（本文件依赖 UIKit 时就没法在 CI 上测了）。
public enum ParagraphBoundary {
    /// `index` 处是否是一个**段落的开头**。
    ///
    /// 段落之间以换行符分隔，所以判据只有一条：**前一个字符是换行**。
    ///
    /// - Parameters:
    ///   - chars: **全文**（`Array(text)`），不是切片 —— 判断「页首是不是段落开头」必须看
    ///     **页首之前**那个字符。
    ///   - index: 待判定的字符偏移。
    /// - Returns: `true` = 段落开头（该行应加首行缩进）；`false` = 段落中间（该行是续行，不加缩进）。
    ///   `index <= 0`（文本开头、含空文本）恒为 `true`；`index >= chars.count`（越界）也返回
    ///   `true` —— 位置落在文本之外时无从判定为半截段落，按「不抑制缩进」这个保守默认取值。
    public static func isParagraphStart(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0, index < chars.count else { return true }
        return chars[index - 1].isNewline
    }

    /// 切片 `slice` 里**第一个段落**占多少个 UTF-16 码元（含结尾的换行符；没有换行就是整个切片）。
    ///
    /// 用途：把切片**第一段**的 `paragraphStyle` 换成「首行不缩进」那一份，切片里**后续**段落
    /// 照旧带缩进（不能把整片切片的缩进都置 0）。
    ///
    /// 两个口径上的要点：
    /// 1. 长度必须按 **UTF-16 码元**算（`NSRange` 的单位），不能拿 `slice.count`（Character 个数）
    ///    当长度用 —— 含 emoji / 组合字符时两者不等（与 `TextCursor` 同一个坑）。
    /// 2. 换行判定同样走 `Character.isNewline`，与 `isParagraphStart` **同源**：
    ///    度量侧与渲染侧因此不会对「哪一段算第一段」产生分歧（`\r\n` 在 Swift 里是**一个**
    ///    Character，`isNewline` 对它为真，长度按 2 个码元算）。
    public static func firstParagraphUTF16Length(in slice: String) -> Int {
        var length = 0
        for character in slice {
            length += character.utf16.count
            if character.isNewline {
                break
            }
        }
        return length
    }
}
