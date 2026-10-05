import Foundation

/// 站点配置（镜像域名可切换）。
///
/// 【与旧项目的唯一差异】加了 `public`（跨 SPM 包必需）。
/// 实测：各镜像同引擎、同规则、同 GBK，换 host 即可。
public struct SiteConfig: Codable, Equatable {
    /// 当前使用的 host（含协议），如 https://www.mumu111111.com
    public var host: String

    public init(host: String) { self.host = host }

    /// 可选镜像列表，主镜像被盾时可切换
    public static let mirrors = [
        "https://www.mumu111111.com",
        "https://www.mumu333333.com",
        "https://www.mumu999999.com"
    ]

    public static let `default` = SiteConfig(host: mirrors[0])

    /// 安卓 UC 浏览器 UA（移动 UA 可直连；桌面 UA 首页可能 404）
    public static let userAgent =
        "Mozilla/5.0 (Linux; U; Android 8.1.0; zh-CN; MI 8 Lite Build/OPM1.171019.019) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/78.0.3904.108 " +
        "UCBrowser/13.2.0.1100 Mobile Safari/537.36"

    public func url(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: host + path)
    }

    /// 书城分类（来自书源 exploreUrl）
    public static let exploreCategories: [ExploreCategory] = [
        .init(title: "全部",   urlTemplate: "/shuku/0-lastupdate-0-{{page}}.html"),
        .init(title: "连载中", urlTemplate: "/shuku/0-lastupdate-1-{{page}}.html"),
        .init(title: "已完本", urlTemplate: "/shuku/0-lastupdate-2-{{page}}.html"),
        .init(title: "总人气", urlTemplate: "/shuku/0-allvisit-0-{{page}}.html"),
        .init(title: "月人气", urlTemplate: "/shuku/0-monthvisit-0-{{page}}.html"),
        .init(title: "字数",   urlTemplate: "/shuku/0-size-0-{{page}}.html"),
        .init(title: "新书",   urlTemplate: "/shuku/0-postdate-0-{{page}}.html"),
        .init(title: "玄幻奇幻", urlTemplate: "/shuku/1-lastupdate-0-{{page}}.html"),
        .init(title: "武侠仙侠", urlTemplate: "/shuku/2-lastupdate-0-{{page}}.html"),
        .init(title: "都市言情", urlTemplate: "/shuku/3-lastupdate-0-{{page}}.html"),
        .init(title: "穿越历史", urlTemplate: "/shuku/4-lastupdate-0-{{page}}.html"),
        .init(title: "科幻灵异", urlTemplate: "/shuku/5-lastupdate-0-{{page}}.html"),
        .init(title: "藏经阁",   urlTemplate: "/shuku/6-lastupdate-0-{{page}}.html"),
        .init(title: "其他类别", urlTemplate: "/shuku/7-lastupdate-0-{{page}}.html")
    ]
}
