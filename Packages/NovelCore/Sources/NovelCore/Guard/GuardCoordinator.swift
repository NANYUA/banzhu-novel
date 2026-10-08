import Foundation

/// 等待用户处理的一次人机验证请求。
public struct GuardRequest: Equatable, Identifiable, Sendable {
    public init(id: UUID = UUID(), siteURL: String) {
        self.id = id
        self.siteURL = siteURL
    }

    public let id: UUID
    public let siteURL: String
}

/// 网络请求与全局验证界面之间的桥。
///
/// 请求遇到盾后在这里挂起；界面完成自动或手动验证后调用 `resolve`，
/// 原请求随即重放。并发请求共用同一次验证结果。
public actor GuardCoordinator {
    public static let shared = GuardCoordinator()

    private var pendingRequest: GuardRequest?
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<GuardRequest>.Continuation] = [:]

    public func events() -> AsyncStream<GuardRequest> {
        AsyncStream { continuation in
            let subscriberID = UUID()
            subscribers[subscriberID] = continuation
            if let pendingRequest {
                continuation.yield(pendingRequest)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID) }
            }
        }
    }

    public func requestPass(siteURL: String) async -> Bool {
        if pendingRequest == nil {
            let request = GuardRequest(siteURL: siteURL)
            pendingRequest = request
            for subscriber in subscribers.values {
                subscriber.yield(request)
            }
        }

        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = continuation
        }
    }

    public func resolve(id: UUID, passed: Bool) {
        guard pendingRequest?.id == id else { return }
        pendingRequest = nil
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: passed)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
