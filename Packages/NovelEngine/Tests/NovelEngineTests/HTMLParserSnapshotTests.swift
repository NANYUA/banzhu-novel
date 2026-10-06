@testable import NovelEngine
import XCTest

/// HTML 解析器快照测试。
///
/// ⚠️ 两个必须同时满足的条件，缺一测试就骗你：
/// 1. `Package.swift` 里 testTarget 必须声明 `resources: [.copy("Fixtures")]`，
///    否则 Fixtures 不会被打进测试 bundle，运行时读到空字符串。
/// 2. Fixture 内容必须严格匹配解析器的正则，别用「想象中」的 HTML。
///    用错的 HTML 会得到 0 结果，那是测试骗人，不是代码错。
final class HTMLParserSnapshotTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        // 从测试 bundle 读取（Bundle.module 由 SwiftPM 生成）
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        guard let url else {
            XCTFail("找不到 Fixture: \(name)，检查 Package.swift 的 resources 声明")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParseSearch() throws {
        let html = try fixture("search.html")
        let results = HTMLParser.parseSearch(html)
        XCTAssertEqual(results.count, 2, "实际 fixture 内容：\(html.prefix(200))")
        XCTAssertEqual(results.first?.title, "Chapter One")
        XCTAssertEqual(results.first?.path, "/1/1/")
    }

    func testParseTOC() throws {
        let html = try fixture("toc.html")
        let chapters = HTMLParser.parseTOC(html)
        XCTAssertEqual(chapters.count, 3, "实际 fixture 内容：\(html.prefix(200))")
        XCTAssertEqual(chapters.first?.name, "Chapter One")
        XCTAssertEqual(chapters.first?.path, "/1/1.html")
    }

    func testParseContent() throws {
        let html = try fixture("content.html")
        let text = HTMLParser.parseContent(html)
        XCTAssertTrue(text.contains("Chapter one text."), "实际：\(text)")
        XCTAssertTrue(text.contains("More text here."), "实际：\(text)")
    }
}
