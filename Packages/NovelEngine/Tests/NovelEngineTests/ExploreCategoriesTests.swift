@testable import NovelEngine
import XCTest

/// 书城分类抽取测试（U5-1）。
///
/// fixture 是**合成**页面（主机与路径都是编的），只保留「首页里带分类导航」这个形状：
/// 分类锚点的 href 形如 `/<一段字母数字下划线连字符>/<数字>_<数字>.html`，第二个数字即页码。
/// 期望值全部写死，正则被改宽/改窄时这里立刻报警。
final class ExploreCategoriesTests: XCTestCase {
    /// 与 `HTMLParserSnapshotTests` 完全一致的查找方式（照抄，不引入第二种）：
    /// 不依赖 `Bundle.module`（xcodebuild 场景下不生成），
    /// 按「测试源码目录 → 上层 Tests 目录」探测，并把尝试过的路径打进断言消息。
    private func fixture(_ name: String) throws -> String {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
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

    private func fixtureCategories() throws -> [ExploreCategory] {
        try HTMLParser.parseExploreCategories(fixture("explore.html"))
    }

    // MARK: - ① 正常抽出 N 条，且保持文档顺序

    func test解析出六条分类且保持文档顺序() throws {
        let titles = try fixtureCategories().map(\.title)
        XCTAssertEqual(titles, [
            "Alpha·Beta", "Gamma", "Delta & Epsilon",
            "Zeta Eta", "Theta·Iota", "Kappa·Lambda",
        ], "分类未按文档顺序抽出：\(titles)")
    }

    func test页码位换成占位符其余部分保持原样() throws {
        let categories = try fixtureCategories()
        XCTAssertEqual(categories.map(\.urlTemplate), [
            "/catalog/1_{{page}}.html",
            "/genre/2_{{page}}.html",
            "/shelf/3_{{page}}.html",
            "/list/4_{{page}}.html",
            "/tag/5_{{page}}.html",
            "/picks/6_{{page}}.html",
        ], "路径模板不对：\(categories.map(\.urlTemplate))")
        XCTAssertEqual(categories.first?.url(page: 1), "/catalog/1_1.html")
        XCTAssertEqual(categories.first?.url(page: 9), "/catalog/1_9.html")
    }

    // MARK: - ② 实体被解码（&middot; / &amp; / &nbsp; / &#…;）

    func test实体被解码为字符() throws {
        let titles = try Set(fixtureCategories().map(\.title))
        XCTAssertTrue(titles.contains("Alpha·Beta"), "&middot; 未解码：\(titles)")
        XCTAssertTrue(titles.contains("Theta·Iota"), "&#183; 未解码：\(titles)")
        XCTAssertTrue(titles.contains("Delta & Epsilon"), "&amp; 未解码：\(titles)")
        XCTAssertTrue(titles.contains("Zeta Eta"), "&nbsp; 未压缩成空格：\(titles)")
    }

    func test锚文本内层标签被剥离且空白被压缩去首尾() throws {
        let titles = try Set(fixtureCategories().map(\.title))
        XCTAssertTrue(titles.contains("Kappa·Lambda"), "内层标签未剥离：\(titles)")
        XCTAssertFalse(titles.contains { $0.contains("<") || $0.contains(">") },
                       "标题残留标签：\(titles)")
        XCTAssertFalse(titles.contains { $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                       "标题未去首尾空白：\(titles)")
    }

    // MARK: - ③ 按标题去重（同一分类在导航 + 页脚各出现一次）

    func test同一分类重复出现时按标题去重() throws {
        let categories = try fixtureCategories()
        XCTAssertEqual(categories.filter { $0.title == "Alpha·Beta" }.count, 1,
                       "同名分类未去重：\(categories.map(\.title))")
        XCTAssertEqual(categories.count, 6, "应只剩 6 条：\(categories.map(\.title))")
        // 去重后保留的是**首次出现**那条（页码 1），不是页脚那条（页码 7）
        XCTAssertEqual(categories.first?.urlTemplate, "/catalog/1_{{page}}.html")
    }

    // MARK: - ④ 非分类链接不被误收

    func test非分类链接不被误收() throws {
        let templates = try fixtureCategories().map(\.urlTemplate).joined(separator: " ")
        XCTAssertFalse(templates.contains("/collection/"), "整目录页链接被误收：\(templates)")
        XCTAssertFalse(templates.contains("/news/"), "带连字符的资讯链接被误收：\(templates)")
        XCTAssertFalse(templates.contains("/42/"), "书籍详情链接被误收：\(templates)")
        XCTAssertFalse(templates.contains("/43/"), "章节链接被误收：\(templates)")
    }

    func test连字符形状与后缀不符的路径都不匹配() {
        let html = """
        <a href="/news/1-beta-2-3.html">Site News</a>
        <a href="/news/1_2.html.bak">Backup Name</a>
        """
        XCTAssertTrue(HTMLParser.parseExploreCategories(html).isEmpty)
    }

    // MARK: - ⑤ 完全不匹配 / 脏输入

    func test完全不匹配时返回空数组() {
        XCTAssertTrue(HTMLParser.parseExploreCategories("").isEmpty)
        XCTAssertTrue(HTMLParser.parseExploreCategories("<html><body><p>no links</p></body></html>").isEmpty)
        XCTAssertTrue(HTMLParser.parseExploreCategories("<a href=\"/collection/\">All Books</a>").isEmpty)
    }

    func test空标题的条目不收() {
        XCTAssertTrue(HTMLParser.parseExploreCategories("<a href=\"/empty/1_1.html\">   </a>").isEmpty)
        XCTAssertTrue(HTMLParser.parseExploreCategories("<a href=\"/empty/1_1.html\"></a>").isEmpty)
    }

    func test垃圾输入不崩溃() {
        XCTAssertNoThrow(HTMLParser.parseExploreCategories("<a href=\"/x/1_1.html\">"))
        XCTAssertNoThrow(HTMLParser.parseExploreCategories("<a href=\"/x/1_1.html\"><span></a>"))
        XCTAssertNoThrow(HTMLParser.parseExploreCategories("&#; <!-- &#xZZ; --"))
    }

    // MARK: - exploreCategories()：请求首页并解析

    func testexploreCategories请求首页并解析分类() async throws {
        let html = try fixture("explore.html")
        // 只放行首页：其它路径一律抛错，于是「请求确实打到 /」由桩自己保证。
        let transport = FakeTransport { url in
            guard url.absoluteString == "https://example.com/" else {
                throw NetworkError.invalidURL(url.absoluteString)
            }
            return html
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(SiteRoutingConfiguration(host: "https://example.com"))

        let categories = try await engine.exploreCategories()

        XCTAssertEqual(categories.count, 6, "实际：\(categories.map(\.title))")
        XCTAssertEqual(categories.first?.title, "Alpha·Beta")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["example.com"])
    }
}
