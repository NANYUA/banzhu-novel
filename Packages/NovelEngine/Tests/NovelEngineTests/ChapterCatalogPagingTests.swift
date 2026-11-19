@testable import NovelEngine
import XCTest

final class ChapterCatalogPagingTests: XCTestCase {
    private func chapterLinks(_ numbers: ClosedRange<Int>) -> String {
        numbers.map { "<a href=\"/42/420/\($0).html\">Chapter \($0)</a>" }.joined()
    }

    private func makeEngine(pages: [String: String]) async -> (NovelEngine, FakeTransport) {
        let transport = FakeTransport { url in
            let reference = String(url.absoluteString.dropFirst("https://example.com".count))
            guard let html = pages[reference] else { throw NetworkError.httpStatus(404) }
            return html
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(SiteRoutingConfiguration(host: "https://example.com"))
        return (engine, transport)
    }

    private func catalogPage(_ numbers: ClosedRange<Int>, page: Int, next: String) -> String {
        """
        <div class="mod block update chapter-list"><div class="hd"><h4>Latest</h4></div>
        <div class="bd"><ul class="list">\(chapterLinks(58 ... 60))</ul></div></div>
        <div class="mod block update chapter-list"><div class="hd"><h4>Chapters</h4></div>
        <div class="bd"><ul class="list">\(chapterLinks(numbers))</ul></div></div>
        <div class="page"><a href="/42/420_1/">首页</a><a class="nextPage" href="\(next)">下页</a>(第\(page)/3页)</div>
        <a href="/42/999/9999.html">Recommendation</a>
        """
    }

    func testCatalogIncludesEveryPageWithoutJumpingToLatestChapter() async throws {
        let (engine, transport) = await makeEngine(pages: [
            "/42/420/": catalogPage(1 ... 20, page: 1, next: "/42/420_2/"),
            "/42/420_2/": catalogPage(21 ... 40, page: 2, next: "/42/420_3/"),
            "/42/420_3/": catalogPage(41 ... 60, page: 3, next: "/42/420_3/"),
        ])

        let chapters = try await engine.chapters(bookPath: "/42/420/")

        XCTAssertEqual(chapters.map(\.number), Array(1 ... 60))
        XCTAssertEqual(Set(chapters.map(\.path)).count, 60)
        XCTAssertEqual(chapters.last?.path, "/42/420/60.html")
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(Array(paths.suffix(2)).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) },
                       ["42/420_2", "42/420_3"])
    }

    func testQueryPaginationPreservesParameters() async throws {
        let (engine, transport) = await makeEngine(pages: [
            "/42/420/": chapterLinks(1 ... 2) + "<a href='?mode=all&amp;page=2'>下页</a>",
            "/42/420/?mode=all&page=2": chapterLinks(3 ... 4),
        ])
        let chapters = try await engine.chapters(bookPath: "/42/420/")
        XCTAssertEqual(chapters.map(\.number), [1, 2, 3, 4])
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths.count, 2)
    }

    func testOptionsCollectAllListedPagesAndDeduplicateBacklinks() async throws {
        let options = """
        <select><option value="/42/420/">1</option>
        <option value="index_2.html">2</option>
        <option value="index_3.html">3</option></select>
        """
        let (engine, transport) = await makeEngine(pages: [
            "/42/420/": chapterLinks(1 ... 2) + options,
            "/42/420/index_2.html": chapterLinks(2 ... 3) + options,
            "/42/420/index_3.html": chapterLinks(3 ... 4) + options,
        ])
        let chapters = try await engine.chapters(bookPath: "/42/420/")
        XCTAssertEqual(chapters.map(\.number), [1, 2, 3, 4])
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths.count, 3)
    }

    func testSinglePageDoesNotFetchChapterBodyOrRecommendations() async throws {
        let (engine, transport) = await makeEngine(pages: [
            "/42/420/": chapterLinks(1 ... 2) + """
            <a href="/42/999/500.html">Other book</a>
            <a href="/42/420/3.html">下一章</a>
            <a rel="next" href="/42/420/4.html">Chapter 4</a>
            <a href="#">下页</a>
            """,
        ])
        let chapters = try await engine.chapters(bookPath: "/42/420/")
        XCTAssertEqual(chapters.map(\.number), [1, 2, 3, 4])
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths.count, 1)
    }

    func testSelfReferenceDoesNotLoop() async throws {
        let (engine, transport) = await makeEngine(pages: [
            "/42/420/": chapterLinks(1 ... 2) + "<a href='/42/420/#bottom'>下页</a>",
        ])
        let chapters = try await engine.chapters(bookPath: "/42/420/")
        XCTAssertEqual(chapters.count, 2)
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths.count, 1)
    }

    func testLaterPageFailureDoesNotReturnPartialCatalog() async throws {
        let (engine, _) = await makeEngine(pages: [
            "/42/420/": chapterLinks(1 ... 25) + "<a href='index_2.html'>下页</a>",
        ])
        do {
            _ = try await engine.chapters(bookPath: "/42/420/")
            XCTFail("Expected the second page failure to propagate")
        } catch NetworkError.httpStatus(404) {}
    }

    func testEmptyLaterPageIsNotAcceptedAsCompleteCatalog() async throws {
        let (engine, _) = await makeEngine(pages: [
            "/42/420/": chapterLinks(1 ... 2) + "<a href='index_2.html'>下页</a>",
            "/42/420/index_2.html": "<html><p>Unavailable</p></html>",
        ])
        do {
            _ = try await engine.chapters(bookPath: "/42/420/")
            XCTFail("Expected an error for an unparseable page")
        } catch ChapterCatalogError.emptyPage {}
    }

    func testExternalAndOtherBookPaginationAreRejected() async throws {
        for next in ["https://other.example/42/420/index_2.html", "/42/421/index_2.html"] {
            let (engine, transport) = await makeEngine(pages: [
                "/42/420/": chapterLinks(1 ... 2) + "<a href='\(next)'>下页</a>",
            ])
            do {
                _ = try await engine.chapters(bookPath: "/42/420/")
                XCTFail("Expected an invalid pagination link error")
            } catch ChapterCatalogError.invalidPageLink {}
            let paths = await transport.requestedPaths()
            XCTAssertEqual(paths.count, 1)
        }
    }

    func testUnboundedPaginationFailsInsteadOfTruncating() async throws {
        let transport = FakeTransport { url in
            let page = Int(url.deletingPathExtension().lastPathComponent.split(separator: "_").last ?? "") ?? 1
            return "<a href='/42/420/\(page).html'>Chapter \(page)</a><a href='index_\(page + 1).html'>下页</a>"
        }
        let engine = NovelEngine(network: transport)
        await engine.setHost("https://example.com")
        do {
            _ = try await engine.chapters(bookPath: "/42/420/index_1.html")
            XCTFail("Expected a page limit error")
        } catch ChapterCatalogError.pageLimitExceeded {}
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths.count, NovelEngine.maxCatalogPages)
    }

    func testFormalDirectoryExcludesLatestBlockAndFooterLinks() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/42/420/"))
        let html = catalogPage(1 ... 20, page: 1, next: "/42/420_2/")
            + "<a href='/42/420/99999.html'>Footer link</a>"
        XCTAssertEqual(HTMLParser.parseChapters(html, baseURL: base).map(\.number), Array(1 ... 20))
        XCTAssertEqual(ChapterCatalogPagination.expectedPageCount(in: html), 3)
    }

    func testMissingNextLinkWithRemainingPagesThrows() async throws {
        let (engine, _) = await makeEngine(pages: [
            "/42/420/": chapterLinks(1 ... 20) + "(第1/3页)<a href='#'>下页</a>",
        ])
        do {
            _ = try await engine.chapters(bookPath: "/42/420/")
            XCTFail("Expected incomplete catalog error")
        } catch ChapterCatalogError.invalidPageLink {}
    }

    func testMissingLogicalPageCannotBeHiddenByFirstPageAlias() async throws {
        let firstPage = chapterLinks(1 ... 20) + """
        (第1/3页)
        <select><option value="/42/420_1/">1</option><option value="/42/420_3/">3</option></select>
        <a href="/42/420_3/">下页</a>
        """
        let lastPage = chapterLinks(41 ... 60) + "(第3/3页)<a href="/42/420_3/">下页</a>"
        let (engine, transport) = await makeEngine(pages: [
            "/42/420/": firstPage,
            "/42/420_1/": firstPage,
            "/42/420_3/": lastPage,
        ])
        do {
            _ = try await engine.chapters(bookPath: "/42/420/")
            XCTFail("Logical page 2 is missing and must not be reported as a complete catalog")
        } catch ChapterCatalogError.invalidPageLink {}
        let requestedPaths = await transport.requestedPaths()
        XCTAssertEqual(requestedPaths.count, 2)
    }

    func testRelativeChapterLinksKeepStableIdentifiers() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/42/420/index_2.html"))
        let html = """
        <a href='9002.html'><span>Chapter 2</span></a>
        <a href='./9001.html'>Chapter 1 &amp; start</a>
        <a href='../421/9000.html'>Other book</a>
        <a href='index_3.html'>下页</a>
        """
        let chapters = HTMLParser.parseChapters(html, baseURL: base)
        XCTAssertEqual(chapters.map(\.number), [9001, 9002])
        XCTAssertEqual(chapters.map(\.path), ["/42/420/9001.html", "/42/420/9002.html"])
        XCTAssertEqual(chapters.first?.name, "Chapter 1 & start")
    }
}
