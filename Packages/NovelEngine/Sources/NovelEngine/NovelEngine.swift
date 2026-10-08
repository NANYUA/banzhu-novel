import Foundation

/// 引擎的站点路由配置。
///
/// `hosts` 与 `navigationURLs` 都只描述同一个站点的入口，不做多站适配。
public struct SiteRoutingConfiguration: Sendable {
    public var hosts: [String]
    public var navigationURLs: [String]
    public var autoSwitchHost: Bool
    public var currentHost: String?
    public var guardPass: (@Sendable (String) async -> Bool)?
    public var onHostChanged: (@Sendable (String) -> Void)?

    public init(
        hosts: [String] = [],
        navigationURLs: [String] = [],
        autoSwitchHost: Bool = true,
        currentHost: String? = nil,
        guardPass: (@Sendable (String) async -> Bool)? = nil,
        onHostChanged: (@Sendable (String) -> Void)? = nil
    ) {
        self.hosts = hosts
        self.navigationURLs = navigationURLs
        self.autoSwitchHost = autoSwitchHost
        self.currentHost = currentHost
        self.guardPass = guardPass
        self.onHostChanged = onHostChanged
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
    private let net: any NetworkTransport

    public init() {
        net = NetworkClient.shared
    }

    init(network: any NetworkTransport) {
        net = network
    }

    public func configureRouting(_ configuration: SiteRoutingConfiguration) {
        routing = configuration
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
        let startingHost = config.host
        var attempted = Set<String>()
        var lastError: Error = NetworkError.badResponse

        var candidates = [startingHost]
        if routing.autoSwitchHost {
            candidates.append(contentsOf: routing.hosts)
        }

        for candidate in candidates {
            let host = Self.normalizedHost(candidate)
            guard !host.isEmpty, attempted.insert(host).inserted else { continue }
            do {
                return try await fetchFromHost(host, path: path, body: body)
            } catch let error as NetworkError {
                guard error.isHostUnavailable else {
                    config = SiteConfig(host: startingHost)
                    throw error
                }
                lastError = error
            }
        }

        if routing.autoSwitchHost {
            for navURL in routing.navigationURLs {
                let resolvedHosts = (try? await resolveCandidatesRaw(fromNav: navURL)) ?? []
                for candidate in resolvedHosts {
                    let host = Self.normalizedHost(candidate)
                    guard !host.isEmpty, attempted.insert(host).inserted else { continue }
                    do {
                        return try await fetchFromHost(host, path: path, body: body)
                    } catch let error as NetworkError {
                        if error.isGuardRequired {
                            config = SiteConfig(host: startingHost)
                            throw error
                        }
                        guard error.isHostUnavailable else {
                            config = SiteConfig(host: startingHost)
                            throw error
                        }
                        lastError = error
                    }
                }
            }
        }

        config = SiteConfig(host: startingHost)
        throw lastError
    }

    private func fetchFromHost(_ host: String, path: String, body: String?) async throws -> String {
        config = SiteConfig(host: host)
        guard let url = config.url(path) else { throw NetworkError.badResponse }
        let html = try await performWithGuard(url: url, body: body)
        routing.onHostChanged?(host)
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

    private func resolveCandidatesRaw(fromNav navURL: String) async throws -> [String] {
        guard let url = URL(string: navURL) else { throw NetworkError.badResponse }
        let html = try await performWithGuard(url: url, body: nil)
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
