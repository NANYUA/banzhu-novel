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
            throw NetworkError.badResponse
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
            throw NetworkError.badResponse
        }
        let engine = NovelEngine(network: transport)

        let hosts = try await engine.resolveCandidates(fromNav: "https://nav.example.com")

        XCTAssertEqual(hosts, ["https://mirror001.com", "https://mirror002.com"])
    }
}
