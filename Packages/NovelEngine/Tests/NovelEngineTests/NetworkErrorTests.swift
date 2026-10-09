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
}
