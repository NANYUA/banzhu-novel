@testable import NovelEngine
import XCTest

/// 正文分段测试（U9-3a）：一章被站点切成多个 HTML 时，引擎要把后续段按序取回并拼接。
///
/// 🔴 回归点：改动前 `NovelEngine.content` 只解码第一段 ——
/// 用户看到的现象正是「阅读页正文只能看到第一页」。
///
/// Fixture 一律是**合成样本**：中性主机（example.com）+ 自编路径形状，
/// 不含任何真实站点的域名 / 分类路径 / 书名 / 正文。
/// 定位方式与 `HTMLParserSnapshotTests` 一致（按 `#filePath` 找源码目录），
/// **不用 `Bundle.module`**（xcodebuild 场景下不生成）。
final class ContentPagingTests: XCTestCase {
    /// 从「测试目录 → 包 Tests 目录」两处候选里读 fixture。
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

    /// 「路径 → 页面」的传输桩。
    ///
    /// 页面先读进字典再进闭包：闭包是 `@Sendable` 的，
    /// 在闭包里捕获 XCTestCase（非 Sendable）会引入并发告警。
    private func makeTransport(pages: [String: String]) -> FakeTransport {
        FakeTransport { url in
            guard let html = pages[url.path] else { throw NetworkError.httpStatus(404) }
            return html
        }
    }

    /// host 固定成中性域名，避免环境变量里的镜像把路径拼歪。
    private func makeEngine(_ transport: FakeTransport) async -> NovelEngine {
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(SiteRoutingConfiguration(host: "https://example.com"))
        return engine
    }

    // MARK: - ① 单段章：行为与改动前一致

    func test单段章只请求一次且正文不变() async throws {
        let page = try fixture("content_single.html")
        let transport = makeTransport(pages: ["/sample/2001.html": page])
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/2001.html")

        XCTAssertTrue(text.contains("Single segment alpha."), "实际：\(text)")
        XCTAssertTrue(text.contains("Single segment beta."), "实际：\(text)")
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths, ["/sample/2001.html"], "单段章不得多发请求")
    }

    // MARK: - ② 多段章：按序拼接

    func test三段章按序拼接并按序请求() async throws {
        let pageOne = try fixture("content_paged_1.html")
        let pageTwo = try fixture("content_paged_2.html")
        let pageThree = try fixture("content_paged_3.html")
        let transport = makeTransport(pages: [
            "/sample/1001.html": pageOne,
            "/sample/1001_2.html": pageTwo,
            "/sample/1001_3.html": pageThree,
        ])
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/1001.html")

        XCTAssertTrue(text.contains("Paged segment one."), "实际：\(text)")
        XCTAssertTrue(text.contains("Paged segment two."), "实际：\(text)")
        XCTAssertTrue(text.contains("Paged segment three."), "实际：\(text)")
        let head = try XCTUnwrap(text.range(of: "Paged segment one.")).lowerBound
        let tail = try XCTUnwrap(text.range(of: "Paged segment three.")).lowerBound
        XCTAssertLessThan(head, tail, "分段顺序错乱：\(text)")
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths, ["/sample/1001.html", "/sample/1001_2.html", "/sample/1001_3.html"])
    }

    // MARK: - ③ 终止保护：自指 / 无限延伸

    func test后续段自指时不死循环() async throws {
        let page = try fixture("content_self_ref.html")
        let transport = makeTransport(pages: ["/sample/3001_2.html": page])
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/3001_2.html")

        XCTAssertTrue(text.contains("Self reference segment."), "实际：\(text)")
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths, ["/sample/3001_2.html"], "指回自己的后续段不得被重复请求")
    }

    func test后续段无限延伸时被分页上限截断() async throws {
        // 每段都指向「下一段」且地址各不相同 —— 只有分页上限能终止它。
        let transport = FakeTransport { url in
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "_").map { String($0) }
            let index = (Int(parts.last ?? "1") ?? 1) + 1
            let base = parts.first ?? "4001"
            return """
            <div class="page-content"><p>Endless segment \(index).</p></div>
            <a href="\(base)_\(index).html">Next</a>
            """
        }
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/4001.html")

        XCTAssertTrue(text.contains("Endless segment 2."), "实际：\(text)")
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths.count, NovelEngine.maxContentPages, "请求数必须被分页上限钉死")
    }

    // MARK: - ④ 后续段失败：保留已取到的部分

    func test后续段取失败时保留已取到的部分() async throws {
        let pageOne = try fixture("content_paged_1.html")
        let transport = FakeTransport { url in
            guard url.path == "/sample/1001.html" else { throw NetworkError.httpStatus(500) }
            return pageOne
        }
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/1001.html")

        XCTAssertTrue(text.contains("Paged segment one."), "已取到的第一段必须保留：\(text)")
        XCTAssertFalse(text.contains("Paged segment two."), "第二段没取到，不该凭空出现：\(text)")
    }

    // MARK: - ⑤ 形状判断：只收「相对的分段地址」，不误收其它链接

    func test形状判断取内联脚本里的分段地址() throws {
        let html = try fixture("content_paged_1.html")
        XCTAssertEqual(HTMLParser.nextSegmentReference(in: html), "1001_2.html")
    }

    func test形状判断取相对引用形式的分段地址() throws {
        let html = try fixture("content_paged_2.html")
        XCTAssertEqual(HTMLParser.nextSegmentReference(in: html), "1001_3.html")
    }

    func test形状判断不误收绝对路径与粘前缀的同形链接() throws {
        let html = try fixture("content_links_only.html")
        XCTAssertNil(HTMLParser.nextSegmentReference(in: html),
                     "绝对路径 / 绝对地址 / 粘前缀的同形文件名都不得被当成后续段")
    }

    func test只有其它形状链接的章节只请求一次() async throws {
        let page = try fixture("content_links_only.html")
        let transport = makeTransport(pages: ["/sample/5001.html": page])
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/5001.html")

        XCTAssertTrue(text.contains("Links only segment."), "实际：\(text)")
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths, ["/sample/5001.html"], "误收其它链接会表现为多发请求")
    }

    func test空页面返回无后续段() {
        XCTAssertNil(HTMLParser.nextSegmentReference(in: ""))
    }
}
