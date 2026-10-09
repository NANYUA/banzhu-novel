@testable import NovelEngine
import XCTest

/// 恢复流程、冷却与并行相关的路由测试。
final class HostRoutingRecoveryTests: XCTestCase {
    func test恢复全部失败后冷却期内只重试当前host() async {
        let transport = FakeTransport { url in
            if url.host == "nav.example.com" {
                return "<a href=\"https://mirror001.com\">入口</a>"
            }
            throw NetworkError.transport(URLError(.timedOut))
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

        // 第一轮：探测已保存 host + 解析导航，全部失败 → 进入恢复冷却。
        _ = try? await engine.requestForTesting(path: "/chapter.html")
        let firstRound = await transport.requestedHosts()
        XCTAssertTrue(firstRound.contains("nav.example.com"))

        // 冷却期内：不探测其它 host、不解析导航，只对当前 host 重试一次。
        _ = try? await engine.requestForTesting(path: "/chapter.html")
        let secondRound = await transport.requestedHosts()
        XCTAssertEqual(Array(secondRound.dropFirst(firstRound.count)), ["one.example"])
    }

    func test验证等待期间探测继续() async throws {
        let gate = GuardGate()
        let signal = ProbeSignal()
        let transport = FakeTransport { url in
            switch url.host {
            case "one.example":
                if await gate.consumePass() {
                    return "ok-one"
                }
                throw NetworkError.guarded
            case "five.example":
                await signal.markProbed()
                throw NetworkError.guarded
            default:
                throw NetworkError.guarded
            }
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: [
                    "https://two.example",
                    "https://three.example",
                    "https://four.example",
                    "https://five.example",
                ],
                autoSwitchHost: true,
                currentHost: "https://one.example",
                guardPass: { url in
                    guard url.contains("one.example") else { return false }
                    // 验证在等待期间，第二批探测必须已经跑起来。
                    let probed = await signal.waitUntilProbed()
                    await gate.markPassed()
                    return probed
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "ok-one")
        let probedDuringVerification = await signal.didProbeDuringVerification()
        XCTAssertTrue(probedDuringVerification)
    }

    func test验证失败后切换下一个guardedHost() async throws {
        let gate = GuardGate()
        let transport = FakeTransport { url in
            if url.host == "one.example" || url.host == "two.example" {
                if await gate.consumePass() {
                    return "ok-\(url.host ?? "")"
                }
                throw NetworkError.guarded
            }
            throw NetworkError.badResponse
        }
        let engine = NovelEngine(network: transport)
        await engine.configureRouting(
            SiteRoutingConfiguration(
                hosts: ["https://two.example"],
                autoSwitchHost: true,
                currentHost: "https://one.example",
                hostStates: [HostRouteState(value: "https://two.example", status: .guarded)],
                guardPass: { url in
                    // 第一个 host 验证失败，第二个成功。
                    guard !url.contains("one.example") else { return false }
                    await gate.markPassed()
                    return true
                }
            )
        )

        let html = try await engine.requestForTesting(path: "/chapter.html")

        XCTAssertEqual(html, "ok-two.example")
        let hosts = await transport.requestedHosts()
        XCTAssertTrue(hosts.contains("one.example"))
        XCTAssertTrue(hosts.contains("two.example"))
    }
}
