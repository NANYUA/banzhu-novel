import Foundation

/// 站点配置（参数通过环境变量注入，不硬编码）。
struct SiteConfig {
    /// 默认配置（从环境变量读取）
    static let `default`: SiteConfig = {
        let host = ProcessInfo.processInfo.environment["SITE_HOST"] ?? "https://example.com"
        return SiteConfig(host: host)
    }()

    let host: String
    var mirrorPatterns: [String] = []

    init(host: String, mirrorPatterns: [String] = []) {
        self.host = host
        self.mirrorPatterns = mirrorPatterns
    }
}
