@testable import NovelEngine
import XCTest

/// HTML 解析器快照测试。
///
/// ⚠️ 两个必须同时满足的条件，缺一测试就骗你：
/// 1. Fixture 必须能被找到（下面 fixture() 会打印所有尝试过的路径）
/// 2. Fixture 内容必须严格匹配解析器的正则，别用「想象中」的 HTML
///    用错的 HTML 会得到 0 结果，那是测试骗人，不是代码错。
final class HTMLParserSnapshotTests: XCTestCase {
    /// 从多个候选位置查找 fixture。
    ///
    /// 不依赖 `Bundle.module`（它在 xcodebuild 场景下不存在），
    /// 而是按「源码目录 → 构建目录」的顺序探测，并把尝试过程打进断言消息，
    /// 这样即使定位失败，CI 日志也能直接指出问题。
    private func fixture(_ name: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let testDir = thisFile.deletingLastPathComponent()

        let candidates = [
            testDir.appendingPathComponent("Fixtures/\(name)"),
            testDir.deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"),
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }

        let tried = candidates.map(\.path).joined(separator: "\n  ")
        XCTFail("找不到 Fixture '\(name)'，已尝试：\n  \(tried)")
        return ""
    }

    func testParseSearch() throws {
        let html = try fixture("search.html")
        let results = HTMLParser.parseSearch(html)
        XCTAssertEqual(results.count, 2, "实际 fixture 内容：\(html.prefix(300))")
        XCTAssertEqual(results.first?.title, "Chapter One")
        XCTAssertEqual(results.first?.path, "/1/1/")
    }

    func testParseTOC() throws {
        let html = try fixture("toc.html")
        let chapters = HTMLParser.parseTOC(html)
        XCTAssertEqual(chapters.count, 3, "实际 fixture 内容：\(html.prefix(300))")
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
