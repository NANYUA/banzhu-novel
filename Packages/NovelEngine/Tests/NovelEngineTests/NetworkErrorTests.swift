import Foundation
@testable import NovelEngine
import XCTest

/// `NetworkError` 的重试判定（H4）。
///
/// 背景：原先 `.transport` 一律重试 —— 调用侧共 4 次尝试、退避 `1.5s × (attempt+1)` ≈ 9 秒。
/// 对「不可能自愈」的错误（DNS 查不到、证书不受信、压根没网、任务被取消）只是让用户白等。
final class NetworkErrorTests: XCTestCase {
    func test永久性传输错误不重试() {
        let permanent: [URLError.Code] = [
            .cannotFindHost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateHasBadDate,
            .secureConnectionFailed,
            .unsupportedURL,
            .badURL,
            .appTransportSecurityRequiresSecureConnection,
            .cannotLoadFromNetwork,
            .dataNotAllowed,
            .userAuthenticationRequired,
            .cancelled,
        ]

        for code in permanent {
            XCTAssertFalse(
                NetworkError.transport(URLError(code)).shouldRetry,
                "\(code) 不可能因为再等 9 秒而自愈，不应重试（H4）"
            )
        }
    }

    func test瞬时传输错误仍然重试() {
        let transient: [URLError.Code] = [
            .timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .resourceUnavailable,
        ]

        for code in transient {
            XCTAssertTrue(
                NetworkError.transport(URLError(code)).shouldRetry,
                "\(code) 可能是瞬时抖动，应保留退避重试"
            )
        }
    }

    func test非URLError的传输错误不重试() {
        // 任务取消在这条链路上不一定是 URLError，也绝不能重试。
        XCTAssertFalse(NetworkError.transport(CancellationError()).shouldRetry)
    }

    func test本次改动未动既有分类() {
        XCTAssertFalse(NetworkError.guarded.shouldRetry)
        XCTAssertFalse(NetworkError.httpStatus(403).shouldRetry)
        XCTAssertFalse(NetworkError.noCandidates(296).shouldRetry)

        XCTAssertTrue(NetworkError.nonHTTPResponse("https://example.com").shouldRetry)
        XCTAssertTrue(NetworkError.decodeFailed.shouldRetry)
    }

    // MARK: - 收枘入口的分类（H4 收尾）

    /// `NetworkClient.wrap` 是重试循环的**唯一**收枘入口。
    ///
    /// ⚠️ 这一组**只**守「收枘后的分类对不对」，**不**证明循环会去问 `shouldRetry`：
    /// 它们直接调 `wrap`，把循环的 `catch` 改回「收枘完直接睡」的旧写法照样全绿
    /// （H4 第一次改歪就是这么漏掉的）。循环行为本身由 `RetryLoopTests` 驱动守。
    func test循环入口对URLError走同一套分类() {
        XCTAssertFalse(NetworkClient.wrap(URLError(.cannotFindHost)).shouldRetry)
        XCTAssertFalse(NetworkClient.wrap(URLError(.notConnectedToInternet)).shouldRetry)
        XCTAssertFalse(NetworkClient.wrap(URLError(.serverCertificateUntrusted)).shouldRetry)
        XCTAssertFalse(NetworkClient.wrap(URLError(.unsupportedURL)).shouldRetry)

        XCTAssertTrue(NetworkClient.wrap(URLError(.timedOut)).shouldRetry)
        XCTAssertTrue(NetworkClient.wrap(URLError(.networkConnectionLost)).shouldRetry)
    }

    func test循环入口对已是NetworkError的原样透传不二次包装() {
        XCTAssertFalse(NetworkClient.wrap(NetworkError.guarded).shouldRetry)
        XCTAssertFalse(NetworkClient.wrap(NetworkError.httpStatus(403)).shouldRetry)
        XCTAssertFalse(NetworkClient.wrap(NetworkError.noCandidates(296)).shouldRetry)

        XCTAssertTrue(NetworkClient.wrap(NetworkError.nonHTTPResponse("https://example.com")).shouldRetry)
        XCTAssertTrue(NetworkClient.wrap(NetworkError.decodeFailed).shouldRetry)

        guard case .guarded = NetworkClient.wrap(NetworkError.guarded) else {
            return XCTFail("已经是 NetworkError 的不应再被包一层 .transport")
        }
    }

    func test循环入口对未知错误与取消一律不重试() {
        // 任务取消走的是非 URLError，绝不能重试 —— 用户已经离开这个请求了。
        XCTAssertFalse(NetworkClient.wrap(CancellationError()).shouldRetry)

        // 收枘结果要保住原始错误，否则上层显示不出真实原因。
        guard case let .transport(inner) = NetworkClient.wrap(URLError(.cannotFindHost)) else {
            return XCTFail("URLError 应被收枘成 .transport")
        }
        XCTAssertEqual((inner as? URLError)?.code, .cannotFindHost)
    }

    // MARK: - B0-7 方案 A：把曾被折叠的错误语义拆开

    /// 「非 HTTP 响应」的文案要带上请求地址 —— 排查时得能看出是哪一次请求没拿到响应。
    func test非HTTP响应文案带请求地址() {
        let url = "https://demo.example/1.html"
        let description = NetworkError.nonHTTPResponse(url).errorDescription

        XCTAssertTrue(description?.contains(url) ?? false, "文案应含请求地址，实际 \(description ?? "nil")")
    }

    /// 「地址格式无法识别」的文案要带上原始字符串 —— 这是唯一能反推用户填了什么的信息。
    func test非法地址文案带原始字符串() {
        let raw = "ht tp://demo.example"
        let description = NetworkError.invalidURL(raw).errorDescription

        XCTAssertTrue(description?.contains(raw) ?? false, "文案应含原始地址串，实际 \(description ?? "nil")")
    }

    func test两个新错误的重试与host可用性分类() {
        // 非 HTTP 响应：保持原先「可重试 + 可换 host」的分类，属最小改动。
        XCTAssertTrue(NetworkError.nonHTTPResponse("https://demo.example").shouldRetry)
        XCTAssertTrue(NetworkError.nonHTTPResponse("https://demo.example").isHostUnavailable)

        // 地址非法：重试与换 host 都没有意义，同一个字符串重试多少次还是解析不出来。
        XCTAssertFalse(NetworkError.invalidURL("ht tp://demo.example").shouldRetry)
        XCTAssertFalse(NetworkError.invalidURL("ht tp://demo.example").isHostUnavailable)
    }

    /// 回归意图（B0-7 的根因）：同一个失败原因只对应一个 case。
    ///
    /// 原先「非 HTTP 响应」与「URL 构造失败」都抛同一个兜底错误、都显示「服务器响应异常。」，
    /// 只看文案**无法**反推真实原因，排查因此绕了一大圈。
    func test非法地址与未收到HTTP响应不再共用一个case() {
        let raw = "ht tp://demo.example"
        let invalid = NetworkError.invalidURL(raw)
        let nonHTTP = NetworkError.nonHTTPResponse("https://demo.example")

        guard case let .invalidURL(invalidRaw) = invalid else {
            return XCTFail("地址解析失败应为 .invalidURL，实际 \(invalid)")
        }
        XCTAssertEqual(invalidRaw, raw)

        guard case let .nonHTTPResponse(requestedURL) = nonHTTP else {
            return XCTFail("非 HTTP 响应应为 .nonHTTPResponse，实际 \(nonHTTP)")
        }
        XCTAssertEqual(requestedURL, "https://demo.example")

        // 两者不得再共用同一句文案。
        XCTAssertNotEqual(invalid.errorDescription, nonHTTP.errorDescription)
    }
}
