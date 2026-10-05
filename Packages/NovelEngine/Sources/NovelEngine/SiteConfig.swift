import Foundation

/// 站点配置（单站点，关键参数从环境变量注入，不硬编码）。
///
/// ## 设计原则
/// 公开仓库不允许泄露具体域名、站点特征或业务规则。
/// 所有敏感配置通过环境变量注入，本地开发时通过 `.env` 文件管理。
enum SiteConfig {
    /// 当前使用的 host（含协议），从环境变量读取
    static var defaultHost: String {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment["SITE_HOST"]
        if let host = env, !host.isEmpty {
            return host
        }
        #endif
        return "https://example.com"
    }

    /// 镜像域名匹配正则数组（逗号分隔）。
    ///
    /// 不同站点的镜像域名格式不同，默认提供通用模式。
    /// 如需适配特定站点，在 `.env` 中设置 `SITE_MIRROR_PATTERNS`。
    ///
    /// 示例：
    ///   SITE_MIRROR_PATTERNS="https?://[\\w.-]*site\\d+\\.(?:com|net),https?://[\\w.-]*mirror\\d+\\.(?:com|net)"
    static var mirrorPatterns: [String] {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_MIRROR_PATTERNS"],
           !env.isEmpty {
            return env.components(separatedBy: ",").filter { !$0.isEmpty }
        }
        #endif
        // 默认：通用镜像域名格式（不含具体站点标识）
        return [
            "https?://[\\w.-]*\\d+\\.(?:com|net)"
        ]
    }

    /// 是否启用自动过盾
    static var guardAutoEnabled: Bool {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["GUARD_AUTO"],
           env == "false" || env == "0" {
            return false
        }
        #endif
        return true
    }
}
