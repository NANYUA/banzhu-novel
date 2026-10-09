import Foundation
@testable import NovelCore
import XCTest

/// H1：UTF-16 长度 ↔ Character 个数 的换算。
///
/// `TextKitMeasuring` 拿到的 `characterRange.length` 是 UTF-16 码元数，
/// 而 `Paginator` 的游标是 Character（守恒律：`sum(pages.length) == text.count`）。
/// 换算逻辑放在 NovelCore 就是为了让这一段能在 CI 上被测到。
final class TextCursorTests: XCTestCase {
    // MARK: - 换算表

    func test纯ASCII与BMP汉字一一对应() {
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 3, in: "abcdef"), 3)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 6, in: "abcdef"), 6)
        // BMP 内的汉字每个占 1 个 UTF-16 码元
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 3, in: "汉字测试"), 3)
    }

    func test代理对emoji两个码元算一个字符() {
        // 😀 = U+1F600，UTF-16 下占 2 个码元，但是 1 个 Character
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 2, in: "😀abc"), 1)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 3, in: "😀abc"), 2)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 5, in: "😀abc"), 4)
    }

    func test边界落在字素簇内部时向前取整() {
        // 只取到代理对的前一半 → 不切出半个字符，返回 0
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 1, in: "😀abc"), 0)
        // é = e + U+0301（组合用重音）：1 个 Character、2 个码元
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 1, in: "e\u{301}x"), 0)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 2, in: "e\u{301}x"), 1)
        // 旗标类 emoji 可以占 4 个码元，同样整簇才算一个
        let flag = "🇨🇳"
        XCTAssertEqual(flag.utf16.count, 4)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 3, in: flag), 0)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 4, in: flag), 1)
    }

    func test越界与负数都被夹紧() {
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 999, in: "abc"), 3)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: -5, in: "abc"), 0)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 0, in: "abc"), 0)
        XCTAssertEqual(TextCursor.characterCount(ofUTF16Length: 0, in: ""), 0)
    }

    // MARK: - 与 Paginator 的集成（守恒律）

    func test含emoji的正文分页守住守恒律() {
        // 一页 10 个 UTF-16 码元 = 5 个 emoji。
        let text = String(repeating: "😀", count: 20)
        let pages = paginate(text: text, utf16Budget: 10)

        XCTAssertEqual(pages.map(\.length), [5, 5, 5, 5])
        XCTAssertEqual(pages.reduce(0) { $0 + $1.length }, text.count)
    }

    func test不换算会把每页多塞一倍字符() {
        // 反证：直接把 UTF-16 长度当 Character 用（也就是修复前 TextKitMeasuring 的行为），
        // 同样的「一页 10 个码元」容量会算出每页 10 个 emoji —— 实际是 20 个码元，超了一倍。
        let text = String(repeating: "😀", count: 20)
        let pages = paginate(text: text, utf16Budget: 10, convert: false)

        XCTAssertEqual(pages.map(\.length), [10, 10])
        // 注意：守恒律（sum == text.count）在这里**依然成立**，但它成立是因为 `Paginator`
        // 用 `clamped = min(pageLength, count - cursor)` 从结构上兜住了末尾 —— 不是分页算对了。
        // 被这个错配破坏的是**一页的容量**：同样「一页 10 个码元」的预算，被当成 10 个字符用，
        // 于是每页实际承载 20 个码元 —— 这才是真机上正文溢出被裁的来源。
        XCTAssertEqual(pages.reduce(0) { $0 + $1.length }, text.count)
    }

    // MARK: - 辅助

    private func paginate(
        text: String,
        utf16Budget: Int,
        convert: Bool = true
    ) -> [PageRange] {
        let measurer = UTF16BudgetMeasuring(utf16Budget: utf16Budget, convert: convert)
        return Paginator(measurer: measurer).paginate(
            text: text,
            configuration: PaginationConfiguration(containerSize: CGSize(width: 100, height: 100))
        )
    }
}

/// 假度量：一页最多 `utf16Budget` 个 UTF-16 码元。
///
/// `convert == false` 时模拟修复前的行为（直接把 UTF-16 长度当 Character 返回），
/// 用于反证换算的必要性。
private struct UTF16BudgetMeasuring: TextMeasuring {
    let utf16Budget: Int
    let convert: Bool

    func measurePageLength(
        text: String,
        from: Int,
        configuration _: PaginationConfiguration
    ) -> Int {
        let chars = Array(text)
        guard from >= 0, from < chars.count else { return 0 }
        let tail = String(chars[from...])
        guard convert else { return utf16Budget }
        return TextCursor.characterCount(ofUTF16Length: utf16Budget, in: tail)
    }
}
