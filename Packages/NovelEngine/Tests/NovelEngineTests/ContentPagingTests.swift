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
            // 页号取路径里的「_N」后缀：首段 `4001.html` 没有后缀 ⇒ 第 1 段。
            // 不能写成「末段数字 + 1」—— 首段路径里的 `4001` 是章节号，不是页号，
            // 那样首段就会自称第 4002 段（正是这条测试在 CI 上失败的原因）。
            let page = parts.count > 1 ? (Int(parts.last ?? "1") ?? 1) : 1
            let base = parts.first ?? "4001"
            return """
            <div class="page-content"><p>Endless segment \(page).</p></div>
            <a href="\(base)_\(page + 1).html">Next</a>
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
        XCTAssertEqual(HTMLParser.allSegmentReferences(in: html).first, "1001_2.html")
    }

    func test形状判断取相对引用形式的分段地址() throws {
        let html = try fixture("content_paged_2.html")
        XCTAssertEqual(HTMLParser.allSegmentReferences(in: html).first, "1001_3.html")
    }

    func test形状判断不误收绝对路径与粘前缀的同形链接() throws {
        let html = try fixture("content_links_only.html")
        XCTAssertTrue(HTMLParser.allSegmentReferences(in: html).isEmpty,
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
        XCTAssertTrue(HTMLParser.allSegmentReferences(in: "").isEmpty)
    }

    // MARK: - ⑥ 分页列表里「当前页自己的链接排在第一个」：必须推进到第 2 页

    func test形状判断按文档顺序返回全部同形引用() throws {
        let html = try fixture("content_curr_first_1.html")
        XCTAssertEqual(HTMLParser.allSegmentReferences(in: html), ["2001_1.html", "2001_2.html"],
                       "当前页自己的链接也要被收集到，且保持文档顺序")
        XCTAssertEqual(HTMLParser.allSegmentReferences(in: html).first, "2001_1.html",
                       "第一个命中是「当前页自己」，所以引擎必须按页号挑下一页")
    }

    func test当前页链接排在列表第一个时仍能取到第二页() async throws {
        let pageOne = try fixture("content_curr_first_1.html")
        let pageTwo = try fixture("content_curr_first_2.html")
        let transport = makeTransport(pages: [
            "/sample/2001_1.html": pageOne,
            "/sample/2001_2.html": pageTwo,
        ])
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/2001_1.html")

        XCTAssertTrue(text.contains("Current first segment one."), "实际：\(text)")
        XCTAssertTrue(text.contains("Current first segment two."), "第 2 页必须被取回：\(text)")
        let head = try XCTUnwrap(text.range(of: "Current first segment one.")).lowerBound
        let tail = try XCTUnwrap(text.range(of: "Current first segment two.")).lowerBound
        XCTAssertLessThan(head, tail, "分段顺序错乱：\(text)")
        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths, ["/sample/2001_1.html", "/sample/2001_2.html"],
                       "当前页自己排在列表第一个时，第 2 页仍必须被请求")
    }

    func test无后缀入口不把第一页当成第二页重复取回() async throws {
        let pageOne = try fixture("content_curr_first_1.html")
        let pageTwo = try fixture("content_curr_first_2.html")
        let transport = makeTransport(pages: [
            "/sample/2001.html": pageOne,
            "/sample/2001_2.html": pageTwo,
        ])
        let engine = await makeEngine(transport)

        let text = try await engine.content(chapterPath: "/sample/2001.html")

        let paths = await transport.requestedPaths()
        XCTAssertEqual(paths, ["/sample/2001.html", "/sample/2001_2.html"],
                       "无后缀入口视作第 1 页，不得把 2001_1.html 当成下一页")
        XCTAssertFalse(paths.contains("/sample/2001_1.html"), "同一页正文不得被取两次")
        XCTAssertEqual(occurrences(of: "Current first segment one.", in: text), 1,
                       "第 1 页正文不得出现两次：\(text)")
        XCTAssertTrue(text.contains("Current first segment two."), "实际：\(text)")
    }

    /// 子串在文本里出现的次数（用来断言「同一页正文没有被重复拼接」）。
    private func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }
}
