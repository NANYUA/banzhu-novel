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
        guard let url = URL(string: normalizedNav) else { throw NetworkError.invalidURL(normalizedNav) }
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

    /// 抽首页（`/`）里的分类入口：标题 + 含 `{{page}}` 的路径模板。
    ///
    /// 首页是整页 HTML，且 `NetworkClient` 已经把响应按 GBK 解成字符串
    /// （见 `NetworkClient.attempt` 的 `GBK.decode(data)`），这里拿到的是**已解码文本**，
    /// 无需也不应再解一次码。
    /// 分类是「锦上添花」：解析不出就返回空数组（不抛错），由上层决定怎么兜底 ——
    /// 首页改版或遇盾都不该让书城整页报错。错误语义沿用 `NetworkError`，不另造类型。
    public func exploreCategories() async throws -> [ExploreCategory] {
        let html = try await fetch(path: "/", body: nil)
        return HTMLParser.parseExploreCategories(html)
    }

    // MARK: - 详情

    public func bookInfo(path: String) async throws -> Book {
        let html = try await fetch(path: path, body: nil)
        return HTMLParser.parseBookInfo(html, path: path)
    }

    // MARK: - 目录

    public func chapters(bookPath: String) async throws -> [Chapter] {
        let html = try await fetch(path: bookPath, body: nil)
        guard let url = config.url(bookPath) else { throw NetworkError.invalidURL(bookPath) }
        return HTMLParser.parseChapters(html, baseURL: url)
    }

    // MARK: - 正文（含解码还原）

    /// 一章最多取几段（含第一段）。
    ///
    /// 取值理由：站点按屏切分正文，正常一章 2–4 段，8 段足够覆盖长章；
    /// 同时把「页面互相指向」这类坏数据下的请求数**钉死在 8 次以内** ——
    /// 终止保护靠它 + `visited` 去重两道，绝不无限循环。
    static let maxContentPages = 8

    /// 取一章正文。站点把同一章切成多个 HTML 分段时（后续段地址形如
    /// `<数字>_<数字>.html`，由 `HTMLParser.allSegmentReferences` 按形状收集、
    /// 再按**页号**挑出下一页），把后续段按序取回并拼接 ——
    /// 只取第一段就是「阅读页正文只能看到第一页」。
    ///
    /// 后续段取失败**不整章报错**：已取到的部分照常返回，少一段好过整章空白
    /// （含后续段撞验证盾、用户取消验证的情形）。错误语义沿用 `NetworkError`，
    /// 但只有第一段失败才向上抛。
    public func content(chapterPath: String) async throws -> String {
        let html = try await fetch(path: chapterPath, body: nil)
        var text = ContentDecoder.decode(html: html)
        guard !text.isEmpty else { return "（本章内容为空，可能需要重新过验证或稍后重试）" }

        var visited: Set<String> = [chapterPath]
        var segments = 1
        var next = nextSegmentPath(from: html, currentPath: chapterPath)
        while let path = next, segments < Self.maxContentPages, !visited.contains(path) {
            visited.insert(path)
            do {
                let segmentHTML = try await fetch(path: path, body: nil)
                let segment = ContentDecoder.decode(html: segmentHTML)
                if !segment.isEmpty {
                    text += "\n" + segment
                }
                segments += 1
                next = nextSegmentPath(from: segmentHTML, currentPath: path)
            } catch {
                EngineLog.log(
                    .warning,
                    "content",
                    "第 \(segments + 1) 段取失败，已保留 \(segments) 段：\(path)"
                )
                break
            }
        }
        return text
    }

    /// 把正文页里识别出的分段引用，解析成**下一页**的可请求路径（与当前段同目录）。
    ///
    /// 站点把分页列表放在正文页里，且**当前页自己的链接排在列表第一个**（带当前页标记）。
    /// 只取第一个命中会解析回当前页，`visited` 立刻判重 ⇒ 循环一次都不执行 ⇒
    /// 用户看到的现象是「正文被截断，只有几屏」。
    /// 因此这里按**页号**挑选：章节名相同、页号大于当前页号的**最小**者。
    private func nextSegmentPath(from html: String, currentPath: String) -> String? {
        guard let current = Self.segmentIdentity(of: currentPath),
              let base = config.url(currentPath) else { return nil }
        var next: (path: String, page: Int)?
        for reference in HTMLParser.allSegmentReferences(in: html) {
            guard let path = URL(string: reference, relativeTo: base)?.path,
                  let candidate = Self.segmentIdentity(of: path),
                  candidate.name == current.name,
                  candidate.page > current.page else { continue }
            if let next, next.page <= candidate.page { continue }
            next = (path, candidate.page)
        }
        return next?.path
    }

    /// 从章节路径里取出「章节名 + 页号」，用来判断两个分段是否同章、谁在前谁在后。
    ///
    /// 文件名形如 `<名称>_<页码>.html` ⇒ name = 前段、page = 后段；
    /// 形如 `<名称>.html`（没有 `_页码` 后缀）⇒ page 视为 1 ——
    /// 这样无后缀的章节入口也会直接选中 `<名称>_2.html`，
    /// 而**不会**把 `<名称>_1.html` 当成下一页、重复取到同一页正文。
    /// 取不出文件名主干时返回 nil，调用方据此放弃推进。
    private static func segmentIdentity(of path: String) -> (name: String, page: Int)? {
        let stem = (path as NSString).lastPathComponent
        let base = (stem as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        guard let separator = base.lastIndex(of: "_") else { return (base, 1) }
        let pageText = String(base[base.index(after: separator)...])
        guard let page = Int(pageText) else { return (base, 1) }
        return (String(base[base.startIndex..<separator]), page)
    }

    /// 供测试使用。
    func requestForTesting(path: String, body: String? = nil) async throws -> String {
        try await fetch(path: path, body: body)
    }

    // MARK: - 路由

    private func fetch(path: String, body: String?) async throws -> String {
        guard let url = config.url(path) else { throw NetworkError.invalidURL(path) }
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
