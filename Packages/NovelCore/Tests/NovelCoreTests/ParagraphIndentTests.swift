import Foundation
@testable import NovelCore
import XCTest

/// 行首缩进归一化：`ParagraphIndentStripper.strippingLineIndents(in:)`。
///
/// 背景（owner 真机反馈）：「正文不开首行缩进，所有段落都会默认缩进一格」——
/// 那一格来自**正文原文每段开头的空白字符**（中文站点用全角空格 `U+3000`），
/// 不是我们画的缩进。口径是**总是删掉行首空白**，与「首行缩进」开关无关，
/// 缩进宽度只由设置决定。
///
/// 单独建文件：`ReaderFeatureTests.swift` 已 582 行、类体也很大，
/// 塞进去会顶到 `type_body_length` / `file_length` 的门槛。
final class ParagraphIndentTests: XCTestCase {
    private static let ideographicSpace = "\u{3000}"

    // MARK: - 要删：行首空白（全角空格 / 半角空格 / 制表符）

    func test全角空格行首被删() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: Self.ideographicSpace + "第一段"),
            "第一段"
        )
    }

    func test半角空格行首被删() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "  第一段"),
            "第一段"
        )
    }

    func test制表符行首被删() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "\t\t第一段"),
            "第一段"
        )
    }

    func test连续多个行首空白一起删() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: " " + Self.ideographicSpace + "\t 第一段"),
            "第一段"
        )
    }

    /// 实际形态：多段正文，每段开头都带全角空格 ⇒ 每段行首都被删。
    func test每段行首都被删而换行保留() {
        let text = Self.ideographicSpace + "第一段\n"
            + Self.ideographicSpace + "第二段\n"
            + "  " + Self.ideographicSpace + "第三段"
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: text),
            "第一段\n第二段\n第三段"
        )
    }

    // MARK: - 不删：行内空格 / 换行 / 行尾空白 / 非空白字符

    func test行内空格不受影响() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "abc def"),
            "abc def"
        )
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "  abc def  "),
            "abc def  ",
            "只删行首，行内与行尾的空格都保留"
        )
    }

    func test空行不受影响() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "第一段\n\n\n第二段"),
            "第一段\n\n\n第二段"
        )
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "\n\n第一段"),
            "\n\n第一段",
            "开头的换行不是空白字符，不会被删"
        )
    }

    func test全空白行保持为空行() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "第一段\n" + Self.ideographicSpace + "\n第二段"),
            "第一段\n\n第二段"
        )
    }

    /// 白名单收窄的证据：非白名单的空白字符（不换行空格 `U+00A0`）不会被删。
    func test非白名单空白字符不删() {
        XCTAssertEqual(
            ParagraphIndentStripper.strippingLineIndents(in: "\u{00A0}第一段"),
            "\u{00A0}第一段"
        )
    }

    // MARK: - 边界：空串 / 全空白

    func test空串与全空白不崩() {
        XCTAssertEqual(ParagraphIndentStripper.strippingLineIndents(in: ""), "")
        XCTAssertEqual(ParagraphIndentStripper.strippingLineIndents(in: "   "), "")
        XCTAssertEqual(ParagraphIndentStripper.strippingLineIndents(in: "\n\n"), "\n\n")
    }

    // MARK: - 回归：`displayText` 的旧语义不能被改掉

    /// 末尾多余空白（旧 `trimmingCharacters` 的语义）仍被去掉；章名照旧拼在前面。
    ///
    /// 末尾刻意只用 ASCII 空格与换行（不掺全角空格）—— 这条是**回归保护**，
    /// 判据不该依赖 `CharacterSet.whitespaces` 到底含哪些 Unicode 字符。
    func testdisplayText仍去末尾空白且拼上章名() {
        XCTAssertEqual(
            ReaderFeature.State.displayText(
                chapterName: "第一章",
                text: Self.ideographicSpace + "正文\n" + Self.ideographicSpace + "第二段\n\n  "
            ),
            "第一章\n\n正文\n第二段"
        )
    }

    /// 没有章名时同样做归一化（`chapterName` 为空走的就是这一支）。
    func test无章名时同样归一化() {
        XCTAssertEqual(
            ReaderFeature.State.displayText(
                chapterName: "",
                text: "  " + Self.ideographicSpace + "正文"
            ),
            "正文"
        )
    }

    /// 正文自带章名开头那一支（不拼前缀）也照样归一化 —— 它返回的仍是正文，
    /// 不是标题；这里若返回**未归一化**的原文，缩进会重新漏回屏幕上。
    func test正文以章名开头时不拼前缀但仍归一化() {
        XCTAssertEqual(
            ReaderFeature.State.displayText(
                chapterName: "第一章",
                text: "第一章\n" + Self.ideographicSpace + "正文"
            ),
            "第一章\n正文"
        )
    }

    /// 章名不受影响：标题是拼在前面的，`ParagraphIndentStripper` 只作用于正文。
    func test章名本身不被改写() {
        XCTAssertEqual(
            ReaderFeature.State.displayText(chapterName: " 第一章 ", text: "正文"),
            "第一章\n\n正文"
        )
    }
}
