@testable import NovelEngine
import XCTest

/// 手动模式路由：只用用户选中的 host；需要验证时弹窗并重放原请求。
final class HostRoutingTests: XCTestCase {
    func test只请求用户选中的host不自动切换() async throws {
        let transport = FakeTransport { _ in "ok" }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(host: "https://two.example")
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "ok")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["two.example"])
    }

    func test撞到验证后弹窗并重放原请求() async throws {
        let gate = GuardGate()
        let transport = FakeTransport { url in
            if url.host == "two.example" {
                if await gate.consumePass() {
                    return "after-guard"
                }
                throw NetworkError.guarded
            }
            throw NetworkError.nonHTTPResponse(url.absoluteString)
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                host: "https://two.example",
                guardPass: { url in
                    guard url.contains("two.example") else { return false }
                    await gate.markPassed()
                    return true
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "after-guard")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["two.example", "two.example"])
        let passCount = await gate.passCount()
        XCTAssertEqual(passCount, 1)
    }

    func test用户取消验证时请求失败不重试() async throws {
        let transport = FakeTransport { _ in
            throw NetworkError.guarded
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                host: "https://one.example",
                guardPass: { _ in false }
            )
        )

        do {
            _ = try await engine.requestForTesting(path: "/chapter.html")
            XCTFail("取消验证后应抛错")
        } catch let error as NetworkError {
            guard case .guarded = error else {
                return XCTFail("应为 NetworkError.guarded，实际 \(error)")
            }
        }
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["one.example"])
    }

    func test导航解析返回去重后的host列表() async throws {
        let transport = FakeTransport { url in
            if url.host == "nav.example.com" {
                return """
                <a href="https://mirror001.com">A</a>
                <a href="https://mirror001.com/">重复</a>
                <a href="https://mirror002.com">B</a>
                """
            }
            throw NetworkError.nonHTTPResponse(url.absoluteString)
        }
        let engine = NovelEngine(network: transport)

        let hosts = try await engine.resolveCandidates(fromNav: "https://nav.example.com")

        XCTAssertEqual(hosts, ["https://mirror001.com", "https://mirror002.com"])
    }

    func test导航地址无协议时自动补https() async throws {
        let transport = FakeTransport { url in
            if url.absoluteString == "https://example.com" {
                return "<a href=\"https://mirror001.com\">A</a>"
            }
            throw NetworkError.nonHTTPResponse(url.absoluteString)
        }
        let engine = NovelEngine(network: transport)

        let discovered = try await engine.resolveCandidates(fromNav: "example.com")

        XCTAssertEqual(discovered, ["https://mirror001.com"])
        let requested = await transport.requestedHosts()
        XCTAssertEqual(requested, ["example.com"])
    }

    func test导航解析遇到验证时弹窗并重放() async throws {
        let gate = GuardGate()
        let transport = FakeTransport { _ in
            if await gate.consumePass() {
                return "<a href=\"https://mirror001.com\">A</a>"
            }
            throw NetworkError.guarded
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                host: "https://example.com",
                guardPass: { url in
                    guard url.contains("nav.example.com") else { return false }
                    await gate.markPassed()
                    return true
                }
            )
        )

        let discovered = try await engine.resolveCandidates(fromNav: "https://nav.example.com")

        XCTAssertEqual(discovered, ["https://mirror001.com"])
        let passCount = await gate.passCount()
        XCTAssertEqual(passCount, 1)
    }

    // MARK: - B0-6 Step 3：导航页是 JS 加载器壳时用渲染结果兜底

    /// 只返回 `<script src>` 的加载器壳：纯 GET 0 命中，但渲染后就该拿到候选。
    private static let shellHTML = "<html><body><script src=\"app.js\"></script></body></html>"

    func test纯GET零命中时用渲染结果再匹配出候选() async throws {
        let transport = FakeTransport { _ in Self.shellHTML }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                host: "https://nav.example.com",
                renderNavigation: { _ in
                    """
                    <map><area href="https://mirror001.com" alt="A">
                    <area href="https://mirror002.com" alt="B"></map>
                    """
                }
            )
        )

        let hosts = try await engine.resolveCandidates(fromNav: "https://nav.example.com")

        XCTAssertEqual(hosts, ["https://mirror001.com", "https://mirror002.com"])
    }

    func test纯GET已命中时不再调用渲染器() async throws {
        let transport = FakeTransport { _ in "<a href=\"https://mirror001.com\">A</a>" }
        let engine = NovelEngine(network: transport)
        // 渲染器若被调用，结果里会多出 mirror009 —— 用它反证「已命中就不渲染」。
        await engine.configureRouting(
            SiteRoutingConfiguration(
                host: "https://nav.example.com",
                renderNavigation: { _ in "<a href=\"https://mirror009.com\">B</a>" }
            )
        )

        let hosts = try await engine.resolveCandidates(fromNav: "https://nav.example.com")

        XCTAssertEqual(hosts, ["https://mirror001.com"])
    }

    func test无渲染器时零命中行为与改动前一致() async throws {
        let transport = FakeTransport { _ in Self.shellHTML }
        let engine = NovelEngine(network: transport)

        do {
            _ = try await engine.resolveCandidates(fromNav: "https://nav.example.com")
            XCTFail("0 命中应抛错")
        } catch let error as NetworkError {
            guard case let .noCandidates(bytes) = error else {
                return XCTFail("应为 NetworkError.noCandidates，实际 \(error)")
            }
            XCTAssertEqual(bytes, Self.shellHTML.utf8.count)
        }
    }

    func test渲染器拿不到页面时仍抛noCandidates() async throws {
        let transport = FakeTransport { _ in Self.shellHTML }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                host: "https://nav.example.com",
                renderNavigation: { _ in nil }
            )
        )

        do {
            _ = try await engine.resolveCandidates(fromNav: "https://nav.example.com")
            XCTFail("渲染拿不到页面时应抛错")
        } catch let error as NetworkError {
            guard case let .noCandidates(bytes) = error else {
                return XCTFail("应为 NetworkError.noCandidates，实际 \(error)")
            }
            XCTAssertEqual(bytes, Self.shellHTML.utf8.count)
        }
    }

    func test渲染结果仍无候选时报渲染后的字节数() async throws {
        let transport = FakeTransport { _ in Self.shellHTML }
        let engine = NovelEngine(network: transport)
        let renderedHTML = "<html><body><p>渲染完也没有地址</p></body></html>"
        await engine.configureRouting(
            SiteRoutingConfiguration(
                host: "https://nav.example.com",
                renderNavigation: { _ in renderedHTML }
            )
        )

        do {
            _ = try await engine.resolveCandidates(fromNav: "https://nav.example.com")
            XCTFail("渲染后仍无候选应抛错")
        } catch let error as NetworkError {
            guard case let .noCandidates(bytes) = error else {
                return XCTFail("应为 NetworkError.noCandidates，实际 \(error)")
            }
            XCTAssertEqual(bytes, renderedHTML.utf8.count)
        }
    }

    // MARK: - B0-7 方案 A：地址构造失败独立成 .invalidURL

    /// 导航地址为空（构造不出 URL）时，抛的必须是「地址格式无法识别」，
    /// 而不是含糊的「服务器响应异常」—— 后者正是 B0-7 误判的来源。
    func test导航地址为空时报地址格式无法识别且不发请求() async throws {
        // 前提：空串构造不出 URL —— 这正是「清空导航地址后点拉取」的现场（B0-6 / B0-7）。
        XCTAssertNil(URL(string: ""), "前提：空串应构造不出 URL")

        let transport = FakeTransport { _ in "不该被请求" }
        let engine = NovelEngine(network: transport)

        do {
            _ = try await engine.resolveCandidates(fromNav: "")
            XCTFail("空地址应抛错")
        } catch let error as NetworkError {
            guard case let .invalidURL(raw) = error else {
                return XCTFail("应为 NetworkError.invalidURL，实际 \(error)")
            }
            XCTAssertEqual(raw, "")
        }
        let requested = await transport.requestedHosts()
        XCTAssertTrue(requested.isEmpty, "地址不合法时不应发出请求，实际 \(requested)")
    }
}
