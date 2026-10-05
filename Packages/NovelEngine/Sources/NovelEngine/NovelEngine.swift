import Foundation

/// 书源引擎：对上层 UI 暴露 搜索 / 详情 / 目录 / 正文 四个能力。
///
/// 【与旧项目的唯一差异】`actor` 及其方法加了 `public` —— 旧项目所有代码在同一
/// target，`internal` 就够；拆成 SPM 包后跨包访问必须是 `public`。
/// 内部组合 NetworkClient + HTMLParser + ContentDecoder + GBK。
public actor NovelEngine {
    public static let shared = NovelEngine()

    private var config = SiteConfig.default
    private let net = NetworkClient.shared

    public func setHost(_ host: String) { config = SiteConfig(host: host) }
    public func currentHost() -> String { config.host }

    /// 从导航页抓取**所有**候选小说站域名（供用户选择）。
    public func resolveCandidates(fromNav navURL: String) async throws -> [String] {
        guard let url = URL(string: navURL) else { throw NetworkError.badResponse }
        let html = try await net.get(url)
        let patterns = [
            "https?://[\\w.-]*mumu\\d+\\.(?:com|net)",
            "https?://[\\w.-]*banzhu\\d+\\.(?:com|net)",
            "https?://[\\w.-]*bz\\d+\\.(?:com|net)"
        ]
        var found: [String] = []
        var seen = Set<String>()
        let ns = html as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) {
                var host = ns.substring(with: m.range)
                while host.hasSuffix("/") { host.removeLast() }
                if !seen.contains(host) { seen.insert(host); found.append(host) }
            }
        }
        if found.isEmpty { throw NetworkError.badResponse }
        return found
    }

    /// 从导航页 HTML 里解析出真实的小说站域名。
    /// 导航页通常列出若干镜像入口（如 www.mumuXXXXXX.com），取第一个指向小说站的链接。
    public func resolveHost(fromNav navURL: String) async throws -> String {
        guard let url = URL(string: navURL) else { throw NetworkError.badResponse }
        let html = try await net.get(url)
        // 优先匹配 mumu 系 / banzhu 系 / bz 系镜像域名
        let patterns = [
            "https?://[\\w.-]*mumu\\d+\\.(?:com|net)",
            "https?://[\\w.-]*banzhu\\d+\\.(?:com|net)",
            "https?://[\\w.-]*bz\\d+\\.(?:com|net)"
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let ns = html as NSString
                if let m = re.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)) {
                    var host = ns.substring(with: m.range)
                    // 去掉结尾斜杠
                    while host.hasSuffix("/") { host.removeLast() }
                    return host
                }
            }
        }
        throw NetworkError.badResponse
    }

    // MARK: - 搜索
    /// POST /s.php，body = s=<GBK>&page=N
    public func search(keyword: String, page: Int = 1) async throws -> [Book] {
        guard let url = config.url("/s.php") else { throw NetworkError.badResponse }
        let body = "s=\(GBK.percentEncode(keyword))&page=\(page)"
        let html = try await net.post(url, bodyString: body)
        return HTMLParser.parseBookList(html)
    }

    // MARK: - 书城分类
    public func explore(category: ExploreCategory, page: Int = 1) async throws -> [Book] {
        guard let url = config.url(category.url(page: page)) else { throw NetworkError.badResponse }
        let html = try await net.get(url)
        return HTMLParser.parseBookList(html)
    }

    // MARK: - 详情
    public func bookInfo(path: String) async throws -> Book {
        guard let url = config.url(path) else { throw NetworkError.badResponse }
        let html = try await net.get(url)
        return HTMLParser.parseBookInfo(html, path: path)
    }

    // MARK: - 目录
    public func chapters(bookPath: String) async throws -> [Chapter] {
        guard let url = config.url(bookPath) else { throw NetworkError.badResponse }
        let html = try await net.get(url)
        return HTMLParser.parseChapters(html, baseURL: url)
    }

    // MARK: - 正文（含解码还原）
    public func content(chapterPath: String) async throws -> String {
        guard let url = config.url(chapterPath) else { throw NetworkError.badResponse }
        let html = try await net.get(url)
        let text = ContentDecoder.decode(html: html)
        return text.isEmpty ? "（本章内容为空，可能需要重新过验证或稍后重试）" : text
    }
}
