import Foundation

/// 验证流程的触发梯队。
public enum VerificationStartTier: String, Codable, Equatable, Sendable {
    /// 第一梯队（当前 host）被盾时立即进入验证。
    case first
    /// 先试第二梯队中无需验证的 host；都不可用时再进入验证。
    case second
}

public enum RouteHostStatus: String, Codable, Equatable, Sendable {
    case unknown
    case unguarded
    case guarded
    case unavailable
}

public enum RouteNavigationStatus: String, Codable, Equatable, Sendable {
    case active
    case cooling
    case frozen
    case disabled
}

public struct HostRouteState: Sendable, Equatable {
    public init(
        value: String,
        status: RouteHostStatus,
        coolingUntil: Date? = nil,
        lastSucceededAt: Date? = nil,
        isUser: Bool = false,
        isStandby: Bool = false
    ) {
        self.value = value
        self.status = status
        self.coolingUntil = coolingUntil
        self.lastSucceededAt = lastSucceededAt
        self.isUser = isUser
        self.isStandby = isStandby
    }

    public var value: String
    public var status: RouteHostStatus
    public var coolingUntil: Date?
    public var lastSucceededAt: Date?
    public var isUser: Bool
    public var isStandby: Bool
}

public struct HostStateUpdate: Sendable, Equatable {
    public init(
        value: String,
        status: RouteHostStatus,
        coolingUntil: Date? = nil
    ) {
        self.value = value
        self.status = status
        self.coolingUntil = coolingUntil
    }

    public var value: String
    public var status: RouteHostStatus
    public var coolingUntil: Date?
}

public enum NavigationOutcome: Sendable, Equatable {
    case success
    case failure
}

/// 引擎的站点路由配置。
///
/// `hosts` 与 `navigationURLs` 都只描述同一个站点的入口，不做多站适配。
public struct SiteRoutingConfiguration: Sendable {
    public var hosts: [String]
    public var navigationURLs: [String]
    public var autoSwitchHost: Bool
    public var verificationStartTier: VerificationStartTier
    public var currentHost: String?
    public var hostStates: [HostRouteState]
    public var navigationStates: [String: RouteNavigationStatus]
    public var hostCooldownSeconds: Int
    public var standbyTTLSeconds: Int
    public var guardPass: (@Sendable (String) async -> Bool)?
    public var onHostChanged: (@Sendable (String) -> Void)?
    public var onHostStateChanged: (@Sendable (HostStateUpdate) -> Void)?
    public var onNavigationOutcome: (@Sendable (String, NavigationOutcome) -> Void)?

    public init(
        hosts: [String] = [],
        navigationURLs: [String] = [],
        autoSwitchHost: Bool = true,
        verificationStartTier: VerificationStartTier = .second,
        currentHost: String? = nil,
        hostStates: [HostRouteState] = [],
        navigationStates: [String: RouteNavigationStatus] = [:],
        hostCooldownSeconds: Int = 300,
        standbyTTLSeconds: Int = 900,
        guardPass: (@Sendable (String) async -> Bool)? = nil,
        onHostChanged: (@Sendable (String) -> Void)? = nil,
        onHostStateChanged: (@Sendable (HostStateUpdate) -> Void)? = nil,
        onNavigationOutcome: (@Sendable (String, NavigationOutcome) -> Void)? = nil
    ) {
        self.hosts = hosts
        self.navigationURLs = navigationURLs
        self.autoSwitchHost = autoSwitchHost
        self.verificationStartTier = verificationStartTier
        self.currentHost = currentHost
        self.hostStates = hostStates
        self.navigationStates = navigationStates
        self.hostCooldownSeconds = hostCooldownSeconds
        self.standbyTTLSeconds = standbyTTLSeconds
        self.guardPass = guardPass
        self.onHostChanged = onHostChanged
        self.onHostStateChanged = onHostStateChanged
        self.onNavigationOutcome = onNavigationOutcome
    }
}

/// 书源引擎：对上层 UI 暴露 搜索 / 详情 / 目录 / 正文 四个能力。
///
/// 内部组合 NetworkClient + HTMLParser + ContentDecoder + GBK。
/// 所有网络请求共用同一条路由：当前 host → 已保存 host → 导航页解析出的 host。
public actor NovelEngine {
    public static let shared = NovelEngine()

    private var config = SiteConfig.default
    private var routing = SiteRoutingConfiguration()
    private var unguardedHosts = Set<String>()
    private var guardedHosts = Set<String>()
    private var hostRouteStates: [String: HostRouteState] = [:]
    private var navigationRouteStates: [String: RouteNavigationStatus] = [:]
    private var cooldowns: [String: Date] = [:]
    private let net: any NetworkTransport

    public init() {
        net = NetworkClient.shared
    }

    init(network: any NetworkTransport) {
        net = network
    }

    public func configureRouting(_ configuration: SiteRoutingConfiguration) {
        routing = configuration
        hostRouteStates = Dictionary(
            uniqueKeysWithValues: configuration.hostStates.map {
                (Self.normalizedHost($0.value), $0)
            }
        )
        navigationRouteStates = configuration.navigationStates
        for (host, state) in hostRouteStates {
            if let coolingUntil = state.coolingUntil, coolingUntil > Date() {
                cooldowns[host] = coolingUntil
            }
            switch state.status {
            case .unguarded:
                unguardedHosts.insert(host)
                guardedHosts.remove(host)
            case .guarded:
                guardedHosts.insert(host)
                unguardedHosts.remove(host)
            case .unknown, .unavailable:
                break
            }
        }
        if let currentHost = configuration.currentHost,
           !Self.normalizedHost(currentHost).isEmpty {
            config = SiteConfig(host: Self.normalizedHost(currentHost))
        } else if let firstHost = configuration.hosts.first,
                  !Self.normalizedHost(firstHost).isEmpty {
            config = SiteConfig(host: Self.normalizedHost(firstHost))
        }
    }

    public func setHost(_ host: String) {
        let normalized = Self.normalizedHost(host)
        guard !normalized.isEmpty else { return }
        config = SiteConfig(host: normalized)
        routing.onHostChanged?(normalized)
    }

    public func currentHost() -> String { config.host }

    /// 自动过盾入口。手动验证完成后由 App 同步 Cookie，再让等待中的请求重放。
    public func autoPassGuard(urlString: String) async -> Bool {
        await GuardResolver.shared.autoPass(urlString: urlString)
    }

    /// 从导航页抓取所有候选域名（供用户选择）。
    public func resolveCandidates(fromNav navURL: String) async throws -> [String] {
        try await resolveCandidatesRaw(fromNav: navURL)
    }

    /// 从导航页 HTML 里解析出第一个真实域名。
    public func resolveHost(fromNav navURL: String) async throws -> String {
        guard let host = try await resolveCandidatesRaw(fromNav: navURL).first else {
            throw NetworkError.badResponse
        }
        return host
    }

    // MARK: - 搜索

    public func search(keyword: String, page: Int = 1) async throws -> [Book] {
        let body = "s=\(GBK.percentEncode(keyword))&page=\(page)"
        let html = try await fetch(path: "/s.php", body: body)
        return HTMLParser.parseBookList(html)
    }

    // MARK: - 书城分类

    public func explore(category: ExploreCategory, page: Int = 1) async throws -> [Book] {
        let html = try await fetch(path: category.url(page: page), body: nil)
        return HTMLParser.parseBookList(html)
    }

    // MARK: - 详情

    public func bookInfo(path: String) async throws -> Book {
        let html = try await fetch(path: path, body: nil)
        return HTMLParser.parseBookInfo(html, path: path)
    }

    // MARK: - 目录

    public func chapters(bookPath: String) async throws -> [Chapter] {
        let html = try await fetch(path: bookPath, body: nil)
        guard let url = config.url(bookPath) else { throw NetworkError.badResponse }
        return HTMLParser.parseChapters(html, baseURL: url)
    }

    // MARK: - 正文（含解码还原）

    public func content(chapterPath: String) async throws -> String {
        let html = try await fetch(path: chapterPath, body: nil)
        let text = ContentDecoder.decode(html: html)
        return text.isEmpty ? "（本章内容为空，可能需要重新过验证或稍后重试）" : text
    }

    func requestForTesting(path: String, body: String? = nil) async throws -> String {
        try await fetch(path: path, body: body)
    }

    // MARK: - 路由

    private func fetch(path: String, body: String?) async throws -> String {
        let startingHost = Self.normalizedHost(config.host)
        var attempted = Set<String>()
        var lastError: Error = NetworkError.badResponse
        var guardedQueue: [String] = []
        var enterGuardImmediately = false
        let candidates = routing.autoSwitchHost
            ? orderedCandidates(startingHost: startingHost)
            : [startingHost]

        for candidate in candidates.prefix(6) {
            let host = Self.normalizedHost(candidate)
            guard !host.isEmpty, attempted.insert(host).inserted else { continue }
            guard !isCooling(host) else { continue }
            do {
                let html = try await fetchFromHostWithoutGuard(
                    host,
                    path: path,
                    body: body,
                    notifyHostChange: true
                )
                markHost(host, status: .unguarded)
                return html
            } catch let error as NetworkError {
                if error.isGuardRequired {
                    markHost(host, status: .guarded)
                    guardedQueue.append(host)
                    if routing.verificationStartTier == .first, host == startingHost {
                        enterGuardImmediately = true
                        break
                    }
                    continue
                }
                guard error.isHostUnavailable else {
                    config = SiteConfig(host: startingHost)
                    throw error
                }
                markHost(host, status: .unavailable)
                lastError = error
            }
        }

        if routing.autoSwitchHost,
           !enterGuardImmediately,
           shouldAutoFetchNavigation()
        {
            for navURL in routing.navigationURLs
                where navigationRouteStates[navURL, default: .active] == .active
            {
                do {
                    let resolvedHosts = try await resolveCandidatesRaw(
                        fromNav: navURL,
                        allowGuard: false
                    )
                    routing.onNavigationOutcome?(navURL, .success)
                    for candidate in resolvedHosts.prefix(6) {
                        let host = Self.normalizedHost(candidate)
                        guard !host.isEmpty,
                              !isCooling(host),
                              attempted.insert(host).inserted
                        else {
                            continue
                        }
                        do {
                            let html = try await fetchFromHostWithoutGuard(
                                host,
                                path: path,
                                body: body,
                                notifyHostChange: true
                            )
                            markHost(host, status: .unguarded)
                            return html
                        } catch let error as NetworkError {
                            if error.isGuardRequired {
                                markHost(host, status: .guarded)
                                guardedQueue.append(host)
                                continue
                            }
                            guard error.isHostUnavailable else {
                                config = SiteConfig(host: startingHost)
                                throw error
                            }
                            markHost(host, status: .unavailable)
                            lastError = error
                        }
                    }
                } catch let error as NetworkError {
                    routing.onNavigationOutcome?(navURL, .failure)
                    if error.isGuardRequired {
                        if let navHost = URL(string: navURL).flatMap(\.host) {
                            let host = Self.normalizedHost(navHost)
                            markHost(host, status: .guarded)
                            guardedQueue.append(host)
                        }
                    } else if error.isHostUnavailable {
                        lastError = error
                    } else {
                        config = SiteConfig(host: startingHost)
                        throw error
                    }
                }
            }
        }

        for host in guardedQueue.prefix(2) {
            do {
                let html = try await fetchFromHostWithGuard(
                    host,
                    path: path,
                    body: body,
                    notifyHostChange: true
                )
                markHost(host, status: .unguarded)
                return html
            } catch {
                markHost(
                    host,
                    status: .guarded,
                    coolingUntil: Date().addingTimeInterval(
                        TimeInterval(max(routing.hostCooldownSeconds, 60))
                    )
                )
                lastError = error
            }
        }

        config = SiteConfig(host: startingHost)
        throw lastError
    }

    private func orderedCandidates(startingHost: String) -> [String] {
        let hosts = routing.hosts
            .map(Self.normalizedHost)
            .filter { !$0.isEmpty && !isCooling($0) }
        let standby = standbyHost().map { [$0] } ?? []
        let unguarded = hosts.filter {
            unguardedHosts.contains($0) || hostRouteStates[$0]?.status == .unguarded
        }
        let unknown = hosts.filter {
            !unguardedHosts.contains($0) && !guardedHosts.contains($0)
        }
        let guarded = hosts.filter {
            guardedHosts.contains($0) || hostRouteStates[$0]?.status == .guarded
        }

        var result: [String] = []
        var seen = Set<String>()
        if !isCooling(startingHost) {
            result.append(startingHost)
            seen.insert(startingHost)
        }
        for host in standby + unguarded + unknown + guarded where seen.insert(host).inserted {
            result.append(host)
        }
        return result
    }

    private func markHost(
        _ host: String,
        status: RouteHostStatus,
        coolingUntil: Date? = nil
    ) {
        switch status {
        case .unguarded:
            unguardedHosts.insert(host)
            guardedHosts.remove(host)
            cooldowns[host] = nil
        case .guarded:
            guardedHosts.insert(host)
            unguardedHosts.remove(host)
        case .unknown, .unavailable:
            break
        }
        if let coolingUntil {
            cooldowns[host] = coolingUntil
        }
        routing.onHostStateChanged?(
            HostStateUpdate(value: host, status: status, coolingUntil: coolingUntil)
        )
    }

    private func isCooling(_ host: String) -> Bool {
        if let coolingUntil = cooldowns[host], coolingUntil > Date() {
            return true
        }
        if let coolingUntil = hostRouteStates[host]?.coolingUntil, coolingUntil > Date() {
            return true
        }
        return false
    }

    private func standbyHost() -> String? {
        if let host = hostRouteStates.values.first(where: { $0.isStandby })?.value {
            let normalized = Self.normalizedHost(host)
            if !isCooling(normalized) {
                return normalized
            }
        }
        return hostRouteStates.values
            .filter { $0.status == .unguarded && !$0.isUser && !$0.isStandby }
            .compactMap { state -> (String, Date)? in
                let host = Self.normalizedHost(state.value)
                guard !isCooling(host) else { return nil }
                return (host, state.lastSucceededAt ?? .distantPast)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func shouldAutoFetchNavigation() -> Bool {
        let navigationHostCount = routing.hostStates
            .filter { !$0.isUser && $0.status != .unavailable }
            .count
        let hasStandby = routing.hostStates.contains(where: { $0.isStandby })
        let hasActiveNavigation = routing.navigationURLs.contains {
            navigationRouteStates[$0, default: .active] == .active
        }
        return navigationHostCount <= 1 && !hasStandby && hasActiveNavigation
    }

    private func fetchFromHostWithoutGuard(
        _ host: String,
        path: String,
        body: String?,
        notifyHostChange: Bool
    ) async throws -> String {
        config = SiteConfig(host: host)
        guard let url = config.url(path) else { throw NetworkError.badResponse }
        let html = try await perform(url: url, body: body)
        if notifyHostChange {
            routing.onHostChanged?(host)
        }
        return html
    }

    private func fetchFromHostWithGuard(
        _ host: String,
        path: String,
        body: String?,
        notifyHostChange: Bool
    ) async throws -> String {
        config = SiteConfig(host: host)
        guard let url = config.url(path) else { throw NetworkError.badResponse }
        let html = try await performWithGuard(url: url, body: body)
        if notifyHostChange {
            routing.onHostChanged?(host)
        }
        return html
    }

    private func performWithGuard(url: URL, body: String?) async throws -> String {
        do {
            return try await perform(url: url, body: body)
        } catch let error as NetworkError {
            guard error.isGuardRequired, let guardPass = routing.guardPass else {
                throw error
            }
            let passed = await guardPass(url.absoluteString)
            guard passed else { throw NetworkError.guarded }
            return try await perform(url: url, body: body)
        }
    }

    private func perform(url: URL, body: String?) async throws -> String {
        if let body {
            return try await net.post(url, bodyString: body)
        }
        return try await net.get(url)
    }

    private func resolveCandidatesRaw(
        fromNav navURL: String,
        allowGuard: Bool = true
    ) async throws -> [String] {
        guard let url = URL(string: navURL) else { throw NetworkError.badResponse }
        let html: String
        if allowGuard {
            html = try await performWithGuard(url: url, body: nil)
        } else {
            html = try await perform(url: url, body: nil)
        }
        let patterns = SiteConfig.mirrorPatterns
        var found: [String] = []
        var seen = Set<String>()
        let ns = html as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            for match in regex.matches(
                in: html,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) {
                let host = Self.normalizedHost(ns.substring(with: match.range))
                if !host.isEmpty, seen.insert(host).inserted {
                    found.append(host)
                }
            }
        }
        if found.isEmpty { throw NetworkError.badResponse }
        return found
    }

    private static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix("/") {
            host.removeLast()
        }
        guard !host.isEmpty else { return "" }
        if host.hasPrefix("http://") || host.hasPrefix("https://") {
            return host
        }
        return "https://\(host)"
    }
}
