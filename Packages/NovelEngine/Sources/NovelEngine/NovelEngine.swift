import Foundation

/// 验证等待回调：需要验证时弹窗给用户，完成后 resolve(true/false)。
public typealias GuardPass = @Sendable (String) async -> Bool

/// 引擎的站点配置。手动模式：只用用户选中的 host，不自动切换。
public struct SiteRoutingConfiguration: Sendable {
    public var host: String
    public var guardPass: GuardPass?

    /// 导航页渲染回调（可选）：导航页只是个 JS 加载器壳时，由上层用浏览器引擎
    /// 把脚本跑一遍，再把完成后的 DOM 交回来；拿不到返回 nil。
    /// 引擎只吃闭包、不 import 任何 UI 框架，所以由上层注入。
    public var renderNavigation: (@Sendable (URL) async -> String?)?

    public init(
        host: String,
        guardPass: GuardPass? = nil,
        renderNavigation: (@Sendable (URL) async -> String?)? = nil
    ) {
        self.host = Self.normalizedHost(host)
        self.guardPass = guardPass
        self.renderNavigation = renderNavigation
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

    /// 从导航页抓取所有候选域名。先做一次纯 GET；若 0 命中且上层注入了
    /// `renderNavigation`，再把页面渲染一遍（执行 JS）后匹配第二次。
    /// 不缓存、不自动探索。
    public func resolveCandidates(fromNav navURL: String) async throws -> [String] {
        let normalizedNav = SiteRoutingConfiguration.normalizedHost(navURL)
        guard let url = URL(string: normalizedNav) else { throw NetworkError.badResponse }
        let html = try await performWithGuard(url: url, body: nil)
        let matched = Self.candidateHosts(in: html)
        if !matched.isEmpty { return matched }

        // 纯 GET 0 命中：页面可能只是个 JS 加载器壳（地址清单要执行脚本后才进 DOM）。
        // 只有上层注入了渲染器才多走这一步；没注入时行为与改动前完全一致。
        if let renderNavigation = routing.renderNavigation,
           let rendered = await renderNavigation(url),
           !rendered.isEmpty {
            let renderedMatched = Self.candidateHosts(in: rendered)
            if !renderedMatched.isEmpty { return renderedMatched }
            throw Self.noCandidatesError(bytes: rendered.utf8.count)
        }
        throw Self.noCandidatesError(bytes: html.utf8.count)
    }

    /// 按镜像匹配规则从页面里抽出候选 host（规范化 + 去重）。
    private static func candidateHosts(in html: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        for pattern in SiteConfig.mirrorPatterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            for match in regex.matches(in: html, options: [], range: fullRange) {
                let host = SiteRoutingConfiguration.normalizedHost(ns.substring(with: match.range))
                if !host.isEmpty, seen.insert(host).inserted {
                    found.append(host)
                }
            }
        }
        return found
    }

    /// 0 命中的统一出口：与「响应异常」区分开（页面拿到了，但没匹配到地址）。
    /// 记一条诊断（页面字节数 + 正则条数），便于区分「壳页 / 正则不匹配」两类原因。
    private static func noCandidatesError(bytes: Int) -> NetworkError {
        EngineLog.log(
            .warning,
            "nav",
            "0 候选：页面 \(bytes) 字节，patterns \(SiteConfig.mirrorPatterns.count) 条"
        )
        return NetworkError.noCandidates(bytes)
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
        return try await performWithGuard(url: url, body: body)
    }

    /// 一次带验证兜底的请求：遇盾时通过 `guardPass` 弹窗，由用户手动完成后再重放一次。
    private func performWithGuard(url: URL, body: String?) async throws -> String {
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
