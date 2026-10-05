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
        let patterns = SiteConfig.mirrorPatterns
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
    /// 导航页通常列出若干镜像入口（如 www.mirrorXXXXXX.com），取第一个指向小说站的链接。
    public func resolveHost(fromNav navURL: String) async throws -> String {
        guard let url = URL(string: navURL) else { throw NetworkError.badResponse }
        let html = try await net.get(url)
        // 按配置的镜像域名正则依次匹配
        for p in SiteConfig.mirrorPatterns {
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
}
