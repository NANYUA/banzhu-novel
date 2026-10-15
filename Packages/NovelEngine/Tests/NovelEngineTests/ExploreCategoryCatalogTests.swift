@testable import NovelEngine
import XCTest

final class ExploreCategoryCatalogTests: XCTestCase {
    func test固定目录的维度和值与站点规则一致() {
        XCTAssertEqual(ExploreCategoryCatalog.statuses.map(\.value), ["0", "1", "2"])
        XCTAssertEqual(ExploreCategoryCatalog.sorts.map(\.value), [
            "lastupdate", "allvisit", "monthvisit", "size", "postdate",
        ])
        XCTAssertEqual(ExploreCategoryCatalog.genres.map(\.value), [
            "0", "1", "2", "3", "4", "5", "6", "7",
        ])
        XCTAssertEqual(Set(ExploreCategoryCatalog.allItems.map(\.id)).count, 16)
    }

    func test默认与跨维度组合的每页URL() {
        XCTAssertEqual(
            ExploreCategoryCatalog.defaultCategory.url(page: 1),
            "/shuku/0-lastupdate-0-1.html"
        )
        let selection = ExploreCategoryCatalog.category(
            status: ExploreCategoryCatalog.statuses[2],
            sort: ExploreCategoryCatalog.sorts[1],
            genre: ExploreCategoryCatalog.genres[5]
        )
        XCTAssertEqual(selection.url(page: 3), "/shuku/5-allvisit-2-3.html")
        XCTAssertEqual(selection.value, "2|allvisit|5")
    }

    func test书库URL请求列表并解析书籍() async throws {
        let html = """
        <html><body><ul class="list">
          <li class="column-2"><a class="name" href="/49/49034/">第一本书</a>
            <a class="author" href="/author/1/">作者甲</a></li>
          <li class="column-2"><a class="name" href="/50/50012/">第二本书</a></li>
        </ul></body></html>
        """
        let transport = FakeTransport { url in
            guard ["/shuku/0-lastupdate-0-1.html", "/shuku/0-lastupdate-0-2.html"].contains(url.path) else {
                throw NetworkError.invalidURL(url.absoluteString)
            }
            return html
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(SiteRoutingConfiguration(host: "https://example.com"))
        let category = ExploreCategoryCatalog.defaultCategory
        let first = try await engine.explore(category: category)
        let second = try await engine.explore(category: category, page: 2)
        XCTAssertEqual(first.map(\.title), ["第一本书", "第二本书"])
        XCTAssertEqual(first.first?.author, "作者甲")
        XCTAssertEqual(second.count, 2)
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths, ["/shuku/0-lastupdate-0-1.html", "/shuku/0-lastupdate-0-2.html"])
    }
}
