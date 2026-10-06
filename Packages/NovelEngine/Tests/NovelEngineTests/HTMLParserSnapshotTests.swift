@testable import NovelEngine
import XCTest

/// HTML 解析器快照测试。
///
/// ⚠️ Fixtures 必须严格匹配解析器的正则：
/// - `parseBookList` 找 `<li class="column-2">`，不是任意 div
/// - `parseChapters` 找 `href=".../<数字>.html"`
///
/// 用「想象中」的 HTML 写 fixture 会得到 0 结果，
/// 这种失败是**测试骗人**，不是代码错。
final class HTMLParserSnapshotTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return (try? String(contentsOf: url)) ?? ""
    }

    func testParseSearch() {
        let html = fixture("search.html")
        let results = HTMLParser.parseSearch(html)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Chapter One")
        XCTAssertEqual(results[0].path, "/1/1/")
    }

    func testParseTOC() {
        let html = fixture("toc.html")
        let chapters = HTMLParser.parseTOC(html)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].name, "Chapter One")
        XCTAssertEqual(chapters[0].path, "/1/1.html")
    }

    func testParseContent() {
        let html = fixture("content.html")
        let text = HTMLParser.parseContent(html)
        XCTAssertTrue(text.contains("Chapter one text."), "实际：\(text)")
        XCTAssertTrue(text.contains("More text here."), "实际：\(text)")
    }
}
