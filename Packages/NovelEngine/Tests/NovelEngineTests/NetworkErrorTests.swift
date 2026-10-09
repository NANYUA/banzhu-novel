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

        XCTAssertTrue(NetworkError.badResponse.shouldRetry)
        XCTAssertTrue(NetworkError.decodeFailed.shouldRetry)
    }

    // MARK: - 循环层入口（H4 收尾）

    /// `NetworkClient.wrap` 是重试循环的**唯一**收枘入口。
    ///
    /// 这一组断言是 H4 第一次改歪之后补的：第一次只改了 `shouldRetry` 的属性分类，
    /// 但循环里的通用 `catch` 收枘完就睡了、**从没查过它** —— 而 `URLSession` 抛的正是
    /// `URLError`（走通用 catch），所以那次修复在运行时完全没生效。
    /// 盯住这个入口，「循环真的会问」这件事才有测试守住。
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

        XCTAssertTrue(NetworkClient.wrap(NetworkError.badResponse).shouldRetry)
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
}
