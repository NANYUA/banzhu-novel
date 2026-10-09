import Foundation

/// 配置（域名可切换）。参数通过环境变量注入，不硬编码。
public struct SiteConfig: Codable, Equatable {
    /// 当前使用的 host（含协议）
    public var host: String

    public init(host: String) { self.host = host }

    /// 候选域名列表，主域名被盾时可切换。
    /// 从环境变量读取，未设置时为空数组（由调用方决定如何处理）。
    public static var mirrors: [String] {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_MIRRORS"],
           !env.isEmpty {
            return env.components(separatedBy: ",").filter { !$0.isEmpty }
        }
        #endif
        return []
    }

    public static var `default`: SiteConfig {
        SiteConfig(host: mirrors.first ?? "https://example.com")
    }

    /// 移动端 User-Agent。
    /// 从环境变量读取，未设置时用通用移动 UA。
    public static var userAgent: String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_USER_AGENT"],
           !env.isEmpty {
            return env
        }
        #endif
        return "Mozilla/5.0 (Linux; Android 13; Pixel 7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36"
    }

    /// 把路径拼成完整 URL。已是完整 URL 的直接返回。
    public func url(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: host + path)
    }

    /// 域名匹配正则（导航页里找出候选镜像用）。
    /// 默认给一条通用数字模式，覆盖常见的 `xxx001.com` 形式。
    /// 本地开发可在 `.env` 的 `SITE_MIRROR_PATTERNS` 里覆盖。
    public static var mirrorPatterns: [String] {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_MIRROR_PATTERNS"],
           !env.isEmpty {
            return env.components(separatedBy: ",").filter { !$0.isEmpty }
        }
        #endif
        return ["https?://[\\w.-]*\\d+\\.(?:com|net)"]
    }

    /// 书城分类。
    /// 路径模板从环境变量读取（`标题=模板` 以逗号分隔），未设置时为空。
    public static var exploreCategories: [ExploreCategory] {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_EXPLORE_CATEGORIES"],
           !env.isEmpty {
            return env.components(separatedBy: ",").compactMap { pair in
                let parts = pair.components(separatedBy: "=")
                guard parts.count == 2 else { return nil }
                return ExploreCategory(title: parts[0], urlTemplate: parts[1])
            }
        }
        #endif
        return []
    }
}
