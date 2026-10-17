import Foundation
@testable import NovelCore
import XCTest

/// 切章器测试：标题识别、正文归属、兜底切分。
final class ChapterSplitterTests: XCTestCase {
    private var rules: [ImportChapterRule] {
        BuiltinImportRules.all
    }

    // MARK: - 按规则切

    func test两个标题_各成一章() {
        let text = """
        第一章 起点
        正文一
        第二章 终点
        正文二
        """
        let chapters = ChapterSplitter.split(text: text, rules: rules)
        XCTAssertEqual(chapters.map(\.title), ["第一章 起点", "第二章 终点"])
        XCTAssertEqual(chapters.map(\.body), ["正文一", "正文二"])
    }

    /// 书名页 / 简介 / 广告：合并进第一章正文，**不丢也不单独成章**。
    func test首个标题之前的内容并入第一章() {
        let text = """
        这是简介
        作者的话
        第一章 起点
        正文一
        """
        let chapters = ChapterSplitter.split(text: text, rules: rules)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "第一章 起点")
        XCTAssertTrue(chapters[0].body.contains("这是简介"))
        XCTAssertTrue(chapters[0].body.hasSuffix("正文一"))
    }

    /// 目录页 = 连续几十行只有标题没有正文。丢掉空章，不要把正文也丢掉。
    func test只有标题没有正文的目录页不切出空章() {
        let text = """
        目录
        第一章 起点
        第二章 终点
        正文一
        """
        let chapters = ChapterSplitter.split(text: text, rules: rules)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "第二章 终点")
        XCTAssertTrue(chapters[0].body.contains("正文一"))
    }

    /// 超长行不参与匹配：`第 3 章` 出现在段落中间时不能把段落当标题。
    func test超长行即使含规则字样也不当标题() {
        let longBody = String(repeating: "字", count: 200) + "第 3 章"
        let text = """
        第一章 起点
        \(longBody)
        """
        let chapters = ChapterSplitter.split(text: text, rules: rules)
        XCTAssertEqual(chapters.map(\.title), ["第一章 起点"])
        XCTAssertTrue(chapters[0].body.contains("第 3 章"))
    }

    func test停用的规则不参与匹配() {
        let disabled = rules.map { rule -> ImportChapterRule in
            var copy = rule
            copy.isEnabled = false
            return copy
        }
        let text = """
        第一章 起点
        正文一
        """
        let chapters = ChapterSplitter.split(text: text, rules: disabled, fallbackChunkSize: 1000)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "第 1 部分", "全不命中时应走兜底命名")
    }

    func test坏正则被跳过_其它规则照常工作() {
        let bad = ImportChapterRule(id: "bad", name: "坏", pattern: "第(章")
        let text = """
        第一章 起点
        正文一
        """
        let chapters = ChapterSplitter.split(text: text, rules: [bad] + rules)
        XCTAssertEqual(chapters.map(\.title), ["第一章 起点"])
    }

    func testCRLF换行也能切() {
        let text = "第一章 起点\r\n正文一\r\n第二章 终点\r\n正文二\r\n"
        let chapters = ChapterSplitter.split(text: text, rules: rules)
        XCTAssertEqual(chapters.map(\.title), ["第一章 起点", "第二章 终点"])
        XCTAssertEqual(chapters[0].body, "正文一")
    }

    // MARK: - 兜底：按字数切

    /// owner 口径：一条规则都没命中时 3000 字一章，章名「第 N 部分」。
    func test全不命中_按3000字兜底分章() {
        let text = String(repeating: "字", count: 6500)
        let chapters = ChapterSplitter.split(text: text, rules: [])
        XCTAssertEqual(chapters.map(\.title), ["第 1 部分", "第 2 部分", "第 3 部分"])
        XCTAssertEqual(chapters.map(\.body.count), [3000, 3000, 500])
    }

    /// 切分不能把一个段落劈成两半：拼回去必须与原文一致。
    func test兜底切分不劈开段落() {
        let paragraphs = (0 ..< 40).map { _ in String(repeating: "段", count: 50) }
        let text = paragraphs.joined(separator: "\n")
        let chapters = ChapterSplitter.split(text: text, rules: [], fallbackChunkSize: 500)
        XCTAssertGreaterThan(chapters.count, 1)
        XCTAssertEqual(chapters.map(\.body).joined(separator: "\n"), text)
    }

    func test空白文本_切不出章节() {
        XCTAssertTrue(ChapterSplitter.split(text: "  \n\n \n", rules: rules).isEmpty)
    }

    /// 超长单段（没有换行可退）：必须按硬边界切开，不能无限增长成 1 章。
    func test超长单段_按硬边界切开() {
        let text = String(repeating: "长", count: 1200)
        let chapters = ChapterSplitter.split(text: text, rules: [], fallbackChunkSize: 500)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters.map(\.body.count), [500, 500, 200])
    }
}
