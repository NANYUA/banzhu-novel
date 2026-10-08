@testable import NovelEngine
import XCTest

final class HostRoutingTests: XCTestCase {
    func testHost失效时按已保存列表切换() async throws {
        let changes = HostChangeRecorder()
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
                verificationStartTier: .second,
                currentHost: "https://one.example",
                onHostChanged: { host in
                    changes.record(host)
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "ok")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["one.example", "two.example"])
        let recorded = changes.values()
        XCTAssertEqual(recorded, ["https://two.example"])
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
}

extension HostRoutingTests {
    func test当前host被盾时优先切换未验证host() async throws {
        let gate = GuardGate()
        let changes = HostChangeRecorder()
        let transport = FakeTransport { url in
            if url.host == "one.example" {
                throw NetworkError.guarded
            }
            if url.host == "two.example" {
                return "two-ok"
            }
            throw NetworkError.badResponse
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://two.example"],
                autoSwitchHost: true,
                currentHost: "https://one.example",
                guardPass: { _ in
                    await gate.markPassed()
                    return true
                },
                onHostChanged: { host in
                    changes.record(host)
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "two-ok")
        let passCount = await gate.passCount()
        XCTAssertEqual(passCount, 0)
        let recorded = changes.values()
        XCTAssertEqual(recorded, ["https://two.example"])
    }

    func test冷却中的host不会请求() async throws {
        let transport = FakeTransport { url in
            if url.host == "standby.example" {
                return "standby-ok"
            }
            throw NetworkError.badResponse
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://start.example", "https://standby.example"],
                autoSwitchHost: true,
                verificationStartTier: .second,
                currentHost: "https://start.example",
                hostStates: [
                    HostRouteState(
                        value: "https://start.example",
                        status: .guarded,
                        coolingUntil: Date().addingTimeInterval(600)
                    ),
                    HostRouteState(
                        value: "https://standby.example",
                        status: .unguarded,
                        isStandby: true
                    ),
                ]
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "standby-ok")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["standby.example"])
    }

    func test禁用导航时不会解析导航页() async {
        let transport = FakeTransport { _ in
            throw NetworkError.httpStatus(503)
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: [],
                navigationURLs: ["https://nav.example.com"],
                autoSwitchHost: true,
                currentHost: "https://start.example",
                navigationStates: ["https://nav.example.com": .disabled]
            )
        )

        _ = try? await engine.requestForTesting(path: "/chapter.html")

        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["start.example"])
    }

    func test备用host优先于其它未知host() async throws {
        let transport = FakeTransport { url in
            if url.host == "standby.example" {
                return "standby-ok"
            }
            throw NetworkError.httpStatus(503)
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://unknown.example", "https://standby.example"],
                autoSwitchHost: true,
                currentHost: "https://start.example",
                hostStates: [
                    HostRouteState(
                        value: "https://standby.example",
                        status: .unguarded,
                        isStandby: true
                    ),
                ]
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "standby-ok")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts.first, "start.example")
        XCTAssertTrue(hosts.contains("standby.example"))
    }

    func test第一梯队触发模式在当前host被盾时立即验证() async throws {
        let gate = GuardGate()
        let transport = FakeTransport { url in
            if url.host == "one.example" {
                let shouldPass = await gate.consumePass()
                if !shouldPass {
                    throw NetworkError.guarded
                }
                return "after-guard"
            }
            if url.host == "two.example" {
                return "two-ok"
            }
            throw NetworkError.badResponse
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://two.example"],
                autoSwitchHost: true,
                verificationStartTier: .first,
                currentHost: "https://one.example",
                guardPass: { _ in
                    await gate.markPassed()
                    return true
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "after-guard")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["one.example", "one.example", "one.example"])
        let passCount = await gate.passCount()
        XCTAssertEqual(passCount, 1)
    }

    func test已保存host全失败后从导航网址解析新host() async throws {
        let changes = HostChangeRecorder()
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
                currentHost: "https://one.example",
                onHostChanged: { host in
                    changes.record(host)
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "mirror-ok")
        let hosts = await transport.requestedHosts()
        XCTAssertEqual(hosts, ["one.example", "two.example", "nav.example.com", "mirror001.com"])
        let recorded = changes.values()
        XCTAssertEqual(recorded, ["https://mirror001.com"])
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

    func test切换host后目录仍保存相对路径() async throws {
        let toc = """
        <div><a href="/49/49034/1.html">第1章</a></div>
        """
        let transport = FakeTransport { _ in toc }
        let engine = NovelEngine(network: transport)

        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://two.example"],
                autoSwitchHost: false,
                currentHost: "https://one.example"
            )
        )
        let first = try await engine.chapters(bookPath: "/49/49034/")

        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://one.example"],
                autoSwitchHost: false,
                currentHost: "https://two.example"
            )
        )
        let second = try await engine.chapters(bookPath: "/49/49034/")

        XCTAssertEqual(first.first?.path, "/49/49034/1.html")
        XCTAssertEqual(first.first?.path, second.first?.path)
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

private final class HostChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    func record(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        hosts.append(host)
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }
}
