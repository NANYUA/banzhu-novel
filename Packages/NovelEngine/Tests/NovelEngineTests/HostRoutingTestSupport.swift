@testable import NovelEngine
import XCTest

/// HostRouting 系列测试共用的网络桩与记录器。
actor FakeTransport: NetworkTransport {
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

actor GuardGate {
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

actor ConcurrencyProbe {
    private var active = 0
    private var maximumActive = 0

    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active = max(0, active - 1)
    }

    func maximum() -> Int {
        maximumActive
    }
}

/// 记录「第二批探测是否发生在验证等待期间」。
actor ProbeSignal {
    private var probed = false
    private var probedDuringVerification = false

    func markProbed() {
        probed = true
    }

    /// 最多等 1 秒；超时返回 false，避免实现回归时把 CI 挂死。
    func waitUntilProbed() async -> Bool {
        for _ in 0 ..< 40 {
            if probed {
                probedDuringVerification = true
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func didProbeDuringVerification() -> Bool {
        probedDuringVerification
    }
}

final class HostChangeRecorder: @unchecked Sendable {
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
