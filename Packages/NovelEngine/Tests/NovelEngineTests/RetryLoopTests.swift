import Foundation
@testable import NovelEngine
import XCTest

/// 调用次数计数器。
///
/// 必须是 actor 而不是裸 `var`：`perform` 是 `@Sendable` 闭包，
/// 在并发域之间捕获可变状态在 Swift 6 下直接不合法。
private actor CallCounter {
    private(set) var count = 0
    func increment() {
        count += 1
    }
}

/// 退避等待记录器：把 `sleep` 收到的实参照原样存下来，用于断言退避曲线。
private actor SleepRecorder {
    private(set) var delays: [UInt64] = []
    func record(_ nanoseconds: UInt64) {
        delays.append(nanoseconds)
    }
}

/// 重试**循环本体**的测试（H4 收尾）。
///
/// 背景：H4 第一次改歪 —— `shouldRetry` 的属性分类改对了，但循环里的通用 `catch`
/// 把错误包成 `.transport` 后**直接进退避休眠、从不查 `shouldRetry`**；
/// 而 `URLSession` 抛的正是 `URLError`，必走那条分支，于是修复在运行时完全没生效
/// （DNS 查不到照样白等约 9 秒）。
///
/// `NetworkErrorTests` 里那组 `test循环入口*` 只盯住 `NetworkClient.wrap` 的分类，
/// 把循环的 `catch` 改回旧写法它们照样全绿 —— 所以「循环真的会先收枘、再问 `shouldRetry`」
/// 这件事，只能由本文件直接驱动 `RetryLoop` 来守。
///
/// 退避用 `sleep: { _ in }` 注入，测试不真等约 9 秒。
final class RetryLoopTests: XCTestCase {
    /// 跑一次循环并返回**实际尝试次数**。永不真实等待。
    ///
    /// `perform` 的返回类型写死成 `String`，省得调用处再标注泛型实参。
    private func attemptCount(
        retries: Int = 3,
        _ perform: @Sendable (Int) async throws -> String
    ) async -> Int {
        let counter = CallCounter()
        do {
            let html: String = try await RetryLoop.run(
                retries: retries,
                logContext: "https://example.com",
                sleep: { _ in }
            ) { attempt in
                await counter.increment()
                return try await perform(attempt)
            }
            XCTFail("不该成功：\(html)")
        } catch {
            // 失败是预期结果；具体错误由各条测试单独断言。
        }
        return await counter.count
    }

    /// 收枘后原始 `URLError.Code` 必须没丢，否则上层显示不出真实原因。
    private func assertTransportCode(
        _ error: any Error,
        _ expected: URLError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .transport(inner) = NetworkClient.wrap(error) else {
            return XCTFail("应被收枘成 .transport，实际 \(error)", file: file, line: line)
        }
        XCTAssertEqual((inner as? URLError)?.code, expected, file: file, line: line)
    }

    // MARK: - 不重试：一次就放弃（「去掉约 9 秒白等」的回归证据）

    /// **回归证据**：DNS 查不到是永久性错误，必须恰好只尝试 1 次。
    ///
    /// 循环若退回「收枘完直接睡」的旧写法，这里会是 4 次
    /// （退避 1.5 + 3 + 4.5 = 9 秒白等）。
    func testDNS解析失败恰好只尝试一次() async {
        let attempts = await attemptCount { _ in throw URLError(.cannotFindHost) }

        XCTAssertEqual(attempts, 1, "DNS 查不到不可能因为再等 9 秒而自愈，应立刻把真实原因交给用户")
    }

    /// 无网络同样不可能自愈：一次就放弃。
    func test无网络连接恰好只尝试一次() async {
        let attempts = await attemptCount { _ in throw URLError(.notConnectedToInternet) }

        XCTAssertEqual(attempts, 1, "压根没联网时重试只是白等")
    }

    /// 盾、明确的 HTTP 状态、取消：三类都不重试。
    func test盾与明确的HTTP状态与取消都不重试() async {
        let guarded = await attemptCount { _ in throw NetworkError.guarded }
        XCTAssertEqual(guarded, 1, "遇到盾要用户去处理验证，重试无用")

        let forbidden = await attemptCount { _ in throw NetworkError.httpStatus(403) }
        XCTAssertEqual(forbidden, 1, "服务器已经给出决定（403），继续重试只会加剧风险")

        let cancelled = await attemptCount { _ in throw CancellationError() }
        XCTAssertEqual(cancelled, 1, "用户已经离开这个请求，取消后立刻收手")
    }

    // MARK: - 该重试的仍然重试（别把白名单收窄成「一律不重试」）

    /// 瞬时错误保留退避重试：`retries: 3` → 共 4 次尝试。
    func test超时错误重试满三次共四次尝试() async {
        let attempts = await attemptCount { _ in throw URLError(.timedOut) }

        XCTAssertEqual(attempts, 4, "超时属白名单项，应保留退避重试（总尝试次数 = retries + 1）")
    }

    /// 第 1 次失败、第 2 次成功：返回值照常透出，且不再往下试。
    func test第二次成功则返回结果且共两次尝试() async throws {
        let counter = CallCounter()
        let html: String = try await RetryLoop.run(
            retries: 3,
            logContext: "https://example.com",
            sleep: { _ in }
        ) { attempt in
            await counter.increment()
            if attempt == 0 {
                throw URLError(.timedOut)
            }
            return "<html>ok</html>"
        }

        XCTAssertEqual(html, "<html>ok</html>")
        let attempts = await counter.count
        XCTAssertEqual(attempts, 2, "第 2 次就成功了，不该再往下试")
    }

    // MARK: - 放弃时的语义

    /// 全部失败后抛出的必须是**最后一次**的错误（不能被中间某次覆盖）。
    func test全部失败时抛出最后一次的错误() async {
        let counter = CallCounter()
        do {
            let html: String = try await RetryLoop.run(
                retries: 3,
                logContext: "https://example.com",
                sleep: { _ in }
            ) { attempt in
                await counter.increment()
                // 前三次是超时，最后一次换成连接中断 —— 抛出来的应该是后者。
                throw (attempt == 3 ? URLError(.networkConnectionLost) : URLError(.timedOut))
            }
            XCTFail("不该成功：\(html)")
        } catch {
            assertTransportCode(error, .networkConnectionLost)
        }

        let attempts = await counter.count
        XCTAssertEqual(attempts, 4)
    }

    /// 退避序列 `1.5s × (attempt + 1)`：顺带把「约 9 秒」这个数字钉成断言。
    func test发生三次重试时的退避序列() async {
        let recorder = SleepRecorder()
        do {
            let html: String = try await RetryLoop.run(
                retries: 3,
                logContext: "https://example.com",
                sleep: { await recorder.record($0) }
            ) { _ in
                throw URLError(.timedOut)
            }
            XCTFail("不该成功：\(html)")
        } catch {
            assertTransportCode(error, .timedOut)
        }

        let delays = await recorder.delays
        XCTAssertEqual(
            delays,
            [1_500_000_000, 3_000_000_000, 4_500_000_000],
            "退避应为 1.5s × (attempt + 1)，三次共约 9 秒"
        )
    }
}
