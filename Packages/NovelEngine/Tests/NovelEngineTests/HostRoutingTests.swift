@testable import NovelEngine
import XCTest

final class HostRoutingTests: XCTestCase {
    func testHost失效时按已保存列表切换() async throws {
        let transport = FakeTransport { url in
            if url.host == "one.example" {
                throw NetworkError.transport(URLError(.cannotConnectToHost))
            }
            return "ok"
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://two.example"],
                autoSwitchHost: true,
                currentHost: "https://one.example"
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "ok")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["one.example", "two.example"])
    }

    func test关闭自动换host时只尝试当前host() async throws {
        let transport = FakeTransport { _ in
            throw NetworkError.httpStatus(503)
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://two.example"],
                autoSwitchHost: false,
                currentHost: "https://one.example"
            )
        )

        do {
            _ = try await engine.requestForTesting(path: "/chapter.html")
            XCTFail("应当抛出 host 不可用错误")
        } catch {
            XCTAssertTrue(error is NetworkError)
        }

        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["one.example"])
    }

    func test已保存host全失败后从导航网址解析新host() async throws {
        let transport = FakeTransport { url in
            switch url.host {
            case "one.example", "two.example":
                throw NetworkError.transport(URLError(.timedOut))
            case "nav.example.com":
                return "<a href=\"https://mirror001.com\">入口</a>"
            case "mirror001.com":
                return "mirror-ok"
            default:
                throw NetworkError.badResponse
            }
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://two.example"],
                navigationURLs: ["https://nav.example.com"],
                autoSwitchHost: true,
                currentHost: "https://one.example"
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "mirror-ok")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["one.example", "two.example", "nav.example.com", "mirror001.com"])
    }

    func test遇盾通过后重放原请求() async throws {
        let gate = GuardGate()
        let transport = FakeTransport { _ in
            let shouldPass = await gate.consumePass()
            if !shouldPass {
                throw NetworkError.guarded
            }
            return "after-guard"
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: [],
                autoSwitchHost: true,
                currentHost: "https://one.example",
                guardPass: { _ in
                    await gate.markPassed()
                    return true
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "after-guard")
        let passCount = await gate.passCount()
        XCTAssertEqual(passCount, 1)
    }
}

private actor FakeTransport: NetworkTransport {
    private let handler: @Sendable (URL) async throws -> String
    private var urls: [URL] = []

    init(handler: @escaping @Sendable (URL) async throws -> String) {
        self.handler = handler
    }

    func get(_ url: URL) async throws -> String {
        urls.append(url)
        return try await handler(url)
    }

    func post(_ url: URL, bodyString _: String) async throws -> String {
        urls.append(url)
        return try await handler(url)
    }

    func requestedHosts() -> [String] {
        urls.compactMap(\.host)
    }
}

private actor GuardGate {
    private var didPass = false
    private var count = 0

    func consumePass() -> Bool {
        didPass
    }

    func markPassed() {
        didPass = true
        count += 1
    }

    func passCount() -> Int {
        count
    }
}
