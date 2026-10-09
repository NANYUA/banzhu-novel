import Foundation

/// 验证等待回调：需要验证时弹窗给用户，完成后 resolve(true/false)。
public typealias GuardPass = @Sendable (String) async -> Bool

/// 引擎的站点配置。手动模式：只用用户选中的 host，不自动切换。
public struct SiteRoutingConfiguration: Sendable {
    public var host: String
    public var guardPass: GuardPass?

    public init(host: String, guardPass: GuardPass? = nil) {
        self.host = Self.normalizedHost(host)
        self.guardPass = guardPass
    }

    public static func normalizedHost(_ raw: String) -> String {
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

/// 书源引擎：对上层 UI 暴露 搜索 / 详情 / 目录 / 正文 / 导航解析 五个能力。
///
/// 手动模式（当前产品决策）：
/// - 只用用户选中的 host，不自动切换、不探测、不冷却。
/// - 需要验证时通过 `guardPass` 弹窗，由用户手动完成，然后重放原请求。
public actor NovelEngine {
    public static let shared = NovelEngine()

    private var config = SiteConfig.default
    private var routing = SiteRoutingConfiguration(host: SiteConfig.default.host)
    private let net: any NetworkTransport

    public init() {
        net = NetworkClient.shared
    }

    init(network: any NetworkTransport) {
        net = network
    }

    public func configureRouting(_ configuration: SiteRoutingConfiguration) {
        routing = configuration
        if !configuration.host.isEmpty {
            config = SiteConfig(host: configuration.host)
        }
    }

    public func setHost(_ host: String) {
        let normalized = SiteRoutingConfiguration.normalizedHost(host)
        guard !normalized.isEmpty else { return }
        config = SiteConfig(host: normalized)
    }

    public func currentHost() -> String { config.host }

    // MARK: - 导航解析（只能由按钮触发）

    /// 从导航页抓取所有候选域名。只做一次请求，不缓存、不自动探索。
    public func resolveCandidates(fromNav navURL: String) async throws -> [String] {
        guard let url = URL(string: navURL) else { throw NetworkError.badResponse }
        let html = try await perform(url: url, body: nil)
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
                let host = SiteRoutingConfiguration.normalizedHost(ns.substring(with: match.range))
                if !host.isEmpty, seen.insert(host).inserted {
                    found.append(host)
                }
            }
        }
        if found.isEmpty { throw NetworkError.badResponse }
        return found
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

    /// 供测试使用。
    func requestForTesting(path: String, body: String? = nil) async throws -> String {
        try await fetch(path: path, body: body)
    }

    // MARK: - 路由

    private func fetch(path: String, body: String?) async throws -> String {
        guard let url = config.url(path) else { throw NetworkError.badResponse }
        do {
            return try await perform(url: url, body: body)
        } catch let error as NetworkError {
            guard error.isGuardRequired, let guardPass = routing.guardPass else {
                throw error
            }
            // 需要验证：弹窗给用户手动完成，然后重放一次原请求。
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
}
