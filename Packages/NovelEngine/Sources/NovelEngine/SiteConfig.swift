import Foundation

/// 站点配置（参数通过环境变量注入，不硬编码）。
public struct SiteConfig {
    /// 默认配置（从环境变量读取）
    public static let `default`: SiteConfig = {
        let host = ProcessInfo.processInfo.environment["SITE_HOST"] ?? "https://example.com"
        return SiteConfig(host: host)
    }()

    public let host: String
    public var mirrorPatterns: [String] = []

    /// 移动端 User-Agent
    public static let userAgent: String = {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_USER_AGENT"],
           !env.isEmpty {
            return env
        }
        #endif
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }()

    public init(host: String, mirrorPatterns: [String] = []) {
        self.host = host
        self.mirrorPatterns = mirrorPatterns
    }
}
