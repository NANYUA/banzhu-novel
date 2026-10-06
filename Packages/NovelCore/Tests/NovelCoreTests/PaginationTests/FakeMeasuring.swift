import Foundation
@testable import NovelCore

/// 确定性假度量 —— 不依赖真实排版，让分页算法可测。
///
/// ## 设计
/// 按 Unicode 标量值给字符"宽度"，模拟真实排版：
/// - ASCII（U+0020…U+007E）：窄，宽 1
/// - 中文/全角（U+2E80+ 及 CJK）：宽，宽 2
/// - emoji（U+1F000+ 辅助平面）：最宽，宽 3
///
/// `measurePageLength` 从 `from` 累加宽度，直到超过 `widthBudget`，
/// 返回能放下的字符数。
///
/// 这样测试就能**确定性**地验证守恒律、连续律、空章节、防死循环、
/// 中英混排、emoji、字体变化、容器变化等，不依赖 Apple 排版实现的内部行为。
struct FakeMeasuring: TextMeasuring {
    /// 一页能容纳的总宽度
    let widthBudget: Int

    /// 单字符宽度
    private static func charWidth(_ c: Character) -> Int {
        let scalar = c.unicodeScalars[c.unicodeScalars.startIndex].value
        switch scalar {
        case 0x1F000 ... 0x1FFFF:
            return 3 // emoji / 辅助平面
        case 0x2E80 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xFF00 ... 0xFFEF:
            return 2 // 中文 / 全角 / CJK
        default:
            return 1 // ASCII / 其他
        }
    }

    func measurePageLength(text: String, from: Int, configuration _: PaginationConfiguration) -> Int {
        let chars = Array(text)
        var width = 0
        var count = 0

        for i in from ..< chars.count {
            let w = Self.charWidth(chars[i])
            if width + w > widthBudget {
                break
            }
            width += w
            count += 1
        }
        return count
    }
}
