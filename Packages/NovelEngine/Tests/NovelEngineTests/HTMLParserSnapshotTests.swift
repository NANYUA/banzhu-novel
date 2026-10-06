@testable import NovelEngine
import XCTest

/// HTML 解析器快照测试。
///
/// 测试数据来自 `Fixtures/` 目录，当解析逻辑或站点结构变化时，
/// 这些测试会第一个报警。
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
        XCTAssertEqual(results[0].title, "Chapter 1 Start")
        XCTAssertEqual(results[0].path, "/1/1.html")
    }

    func testParseTOC() {
        let html = fixture("toc.html")
        let chapters = HTMLParser.parseTOC(html)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].name, "Chapter 1 Start")
        XCTAssertEqual(chapters[0].path, "/1/1.html")
    }

    func testParseContent() {
        let html = fixture("content.html")
        let text = HTMLParser.parseContent(html)
        XCTAssertTrue(text.contains("This is the first chapter."))
        XCTAssertTrue(text.contains("Continue reading for more."))
    }
}
