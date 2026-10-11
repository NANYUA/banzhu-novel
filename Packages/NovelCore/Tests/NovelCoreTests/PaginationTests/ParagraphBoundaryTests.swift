import Foundation
@testable import NovelCore
import XCTest

/// 段落边界判据（页首首行缩进）—— 度量侧与渲染侧共用的**唯一**判据。
///
/// 判据本身是纯 Swift，所以能在这里被 CI 覆盖；真正套用它的两个 UIKit 文件
/// （`TextKitMeasuring` / `PageTextView`）在 macOS host 上不参与 `swift test`，
/// **只能真机看**。
final class ParagraphBoundaryTests: XCTestCase {
    // MARK: - isParagraphStart

    func test文本开头算段落开头() {
        XCTAssertTrue(ParagraphBoundary.isParagraphStart(Array("正文第一段"), at: 0))
    }

    func test前一个字符是换行算段落开头() {
        let chars = Array("第一段\n第二段")
        // 「第二段」的「第」在下标 4，前一个字符（下标 3）是 `\n`
        XCTAssertTrue(ParagraphBoundary.isParagraphStart(chars, at: 4))
    }

    func testCRLF之后算段落开头() {
        let chars = Array("第一段\r\n第二段")
        // `\r\n` 在 Swift 里是一个 Character（字素簇）；无论按 1 个还是 2 个字符理解，
        // 下标 4 之前那个字符都是换行 ⇒ 都是段落开头（换行判定走 `Character.isNewline`）
        XCTAssertTrue(ParagraphBoundary.isParagraphStart(chars, at: 4))
    }

    func test段落中间不算段落开头() {
        let chars = Array("第一段的中间")
        XCTAssertFalse(ParagraphBoundary.isParagraphStart(chars, at: 3))
        XCTAssertFalse(ParagraphBoundary.isParagraphStart(chars, at: 5))
    }

    func test空文本与越界索引不崩且给出确定值() {
        XCTAssertTrue(ParagraphBoundary.isParagraphStart([], at: 0))
        XCTAssertTrue(ParagraphBoundary.isParagraphStart([], at: 5))
        XCTAssertTrue(ParagraphBoundary.isParagraphStart(Array("abc"), at: -1))
        // 恰好等于 count 也算越界：位置落在文本之外 ⇒ 按「不抑制缩进」的保守默认
        XCTAssertTrue(ParagraphBoundary.isParagraphStart(Array("abc"), at: 3))
        XCTAssertTrue(ParagraphBoundary.isParagraphStart(Array("abc"), at: 99))
    }

    // MARK: - firstParagraphUTF16Length（切片第一段的覆盖范围）

    func test没有换行时第一段就是整个切片() {
        XCTAssertEqual(ParagraphBoundary.firstParagraphUTF16Length(in: "abc"), 3)
        XCTAssertEqual(ParagraphBoundary.firstParagraphUTF16Length(in: ""), 0)
    }

    func test第一段长度含结尾换行符() {
        XCTAssertEqual(ParagraphBoundary.firstParagraphUTF16Length(in: "ab\ncd"), 3)
        XCTAssertEqual(ParagraphBoundary.firstParagraphUTF16Length(in: "ab\ncd\nef"), 3)
        // `\r\n` 是一个 Character，但占 2 个 UTF-16 码元 ⇒ 长度 1 + 1 + 2 = 4
        XCTAssertEqual(ParagraphBoundary.firstParagraphUTF16Length(in: "ab\r\ncd"), 4)
    }

    func test第一段长度按UTF16码元计() {
        // 😀 占 2 个码元 + "x" 1 个 + "\n" 1 个 = 4（Character 个数只有 3）
        XCTAssertEqual(ParagraphBoundary.firstParagraphUTF16Length(in: "😀x\ny"), 4)
        XCTAssertEqual("😀x\ny".count, 3)
    }
}
