import Foundation

/// 轻量 HTML 提取工具（正则实现，避免引入第三方依赖，便于 GitHub 云端编译）。
/// 规则与已验证的 Python 原型对齐。
enum HTMLParser {
    private static func firstGroup(_ pattern: String, in html: String,
                                   opts: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let m = re.firstMatch(in: html, options: [], range: range),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    private static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 字数归一化："62562" → "6.3万字"；"175万字"/"175万" → "175万字"
    private static func normalizeWords(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: "字数", with: "")
            .replacingOccurrences(of: "：", with: "").replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("万") { return s.hasSuffix("字") ? s : s + "字" }
        if let n = Int(s.filter { $0.isNumber }) {
            if n >= 10000 {
                let wan = Double(n) / 10000.0
                return String(format: "%.0f万字", wan.rounded())
            }
            return "\(n)字"
        }
        return s
    }
    /// 解析形如 href="/区/书号/">书名</a> 的结果（去重）
    static func parseBookList(_ html: String) -> [Book] {
        // 优先按 <li class="column-2"> 单本块解析，可拿到 作者 + 最新章节（列表页无简介）。
        if let blocks = try? NSRegularExpression(
            pattern: "<li[^>]*class=\"column-2[^\"]*\"[^>]*>(.*?)</li>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = html as NSString
            var seen = Set<String>()
            var out: [Book] = []
            let matches = blocks.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > 1 {
                let blk = ns.substring(with: m.range(at: 1))
                guard let path = firstGroup("<a[^>]*class=\"name\"[^>]*href=\"(/\\d+/\\d+/)\"", in: blk)
                    ?? firstGroup("href=\"(/\\d+/\\d+/)\"", in: blk) else { continue }
                let title = (firstGroup("class=\"name\"[^>]*>([^<]+)</a>", in: blk)
                    ?? firstGroup("href=\"/\\d+/\\d+/\"[^>]*>([^<]+)</a>", in: blk) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.count > 1, !seen.contains(path) else { continue }
                seen.insert(path)
                var book = Book(path: path, title: title)
                if let author = firstGroup("class=\"author\"[^>]*>([^<]+)</a>", in: blk)
                    ?? firstGroup("作者[：:]\\s*<a[^>]*>([^<]+)</a>", in: blk) {
                    book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let last = firstGroup("最新章节[：:]\\s*<a[^>]*>([^<]+)</a>", in: blk) {
                    book.lastChapter = stripTags(last).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let words = firstGroup("class=\"words\"[^>]*>\\s*字数[：:]?\\s*([^<]+)</span>", in: blk)
                    ?? firstGroup("字数[：:]\\s*([0-9.]+\\s*[万千]?字?)", in: blk) {
                    book.wordCount = normalizeWords(words.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                out.append(book)
            }
            if !out.isEmpty { return out }
        }
        // 兜底：旧的纯链接匹配
        guard let re = try? NSRegularExpression(
            pattern: "href=\"(/\\d+/\\d+/)\"[^>]*>([^<]+)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [Book] = []
        re.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m, m.numberOfRanges > 2 else { return }
            let path = ns.substring(with: m.range(at: 1))
            let title = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 2, !seen.contains(path) {
                seen.insert(path)
                out.append(Book(path: path, title: title))
            }
        }
        return out
    }

    // MARK: - 书城分类

    /// 解码常见 HTML 实体。
    ///
    /// `&amp;` 放最后解：先解会把 `&amp;middot;` 里的**字面量** `&middot;`
    /// 二次解码成 `·`，那是错译而不是解码。
    private static func decodeEntities(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "&middot;", with: "·")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        out = decodeNumericEntities(out)
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `&#183;` / `&#xB7;` 这类数字实体还原成字符；还原不了的（越界标量、脏输入）原样保留。
    private static func decodeNumericEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "&#(?:[xX]([0-9A-Fa-f]+)|(\\d+));") else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 2 else { continue }
            let isHex = m.range(at: 1).location != NSNotFound
            let digits = ns.substring(with: m.range(at: isHex ? 1 : 2))
            guard let value = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(value) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out.append(Character(scalar))
            cursor = m.range.location + m.range.length
        }
        return out + ns.substring(from: cursor)
    }

    /// 锚文本 → 标题：去内层标签 → 解码实体 → 压缩空白 → 去首尾。
    private static func anchorTitle(_ raw: String) -> String {
        let noTags = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(noTags)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 从首页整页 HTML 抽分类入口（标题 + 含 `{{page}}` 的路径模板）。
    ///
    /// 命中规则是**路径形状**，不是某个站点的固定路径或其他站点字面量：
    /// `/<一段字母数字下划线连字符>/<数字>_<数字>.html`，第二个数字即页码
    /// （第 1 页写作 `_1`），把该数字换成 `{{page}}` 就得到模板。
    /// 于是同一套规则对不同站点、不同分类段名都成立，站点改版改了段名也不会失效。
    ///
    /// 同一条分类在页面上可能重复出现（顶部导航 + 页脚），**按标题去重**且保持文档顺序；
    /// 一条都不匹配时返回空数组 —— 首页改版不该让书城整页抛错。
    /// 只在整页 HTML（首页）上有意义，别拿详情页片段调它。
    static func parseExploreCategories(_ html: String) -> [ExploreCategory] {
        guard let re = try? NSRegularExpression(
            pattern: "<a\\s[^>]*href=\"/([A-Za-z0-9_-]+)/(\\d+)_(\\d+)\\.html\"[^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [ExploreCategory] = []
        re.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m, m.numberOfRanges > 4 else { return }
            let title = anchorTitle(ns.substring(with: m.range(at: 4)))
            guard !title.isEmpty, seen.insert(title).inserted else { return }
            let segment = ns.substring(with: m.range(at: 1))
            let firstNumber = ns.substring(with: m.range(at: 2))
            out.append(ExploreCategory(title: title,
                                       urlTemplate: "/\(segment)/\(firstNumber)_{{page}}.html"))
        }
        return out
    }

    // MARK: - 详情页
    static func parseBookInfo(_ html: String, path: String) -> Book {
        var book = Book(path: path, title: "")
        if let h1 = firstGroup("<h1[^>]*>(.*?)</h1>", in: html) {
            book.title = stripTags(h1)
        }
        if let a = firstGroup("作者[：:]\\s*([^\\s\\n【】<]+)", in: html, opts: [.caseInsensitive]) {
            book.author = a
        }
        if let w = firstGroup("字数[：:]\\s*([0-9.]+\\s*[万千]?字?)", in: html, opts: [.caseInsensitive]) {
            book.wordCount = normalizeWords(w)
        }
        let coverPatterns = [
            "<div[^>]*class=\"[^\"]*(?:cover|book-img|imgbox)[^\"]*\"[^>]*>.*?<img[^>]+src=\"([^\"]+)\"",
            "<img[^>]+(?:id|class)=\"[^\"]*(?:cover|bookimg)[^\"]*\"[^>]+src=\"([^\"]+)\"",
            "<meta[^>]+property=\"og:image\"[^>]+content=\"([^\"]+)\"",
        ]
        for pattern in coverPatterns {
            if let cover = firstGroup(pattern, in: html) {
                book.coverUrl = cover
                break
            }
        }
        if let status = firstGroup("(?:状态|连载状态)[：:]\\s*([^<\\s]+)", in: html) {
            book.status = stripTags(status)
        }
        if let category = firstGroup("(?:分类|类别|所属分类)[：:]\\s*([^<\\s]+)", in: html) {
            book.category = stripTags(category)
        }
        if let last = firstGroup("最新章节[：:]\\s*<a[^>]*>([^<]+)</a>", in: html)
            ?? firstGroup("最新章节[：:]\\s*([^<\\n]+)", in: html) {
            book.lastChapter = stripTags(last)
        }
        if let updated = firstGroup("(?:更新时间|最后更新)[：:]\\s*([^<\\n]+)", in: html) {
            book.lastUpdated = stripTags(updated)
        }
        if let re = try? NSRegularExpression(
            pattern: "class=\"[^\"]*tag[^\"]*\"[^>]*>([^<]+)<",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let ns = html as NSString
            var tags: [String] = []
            var seen = Set<String>()
            for match in re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > 1 else { continue }
                let tag = stripTags(ns.substring(with: match.range(at: 1)))
                if !tag.isEmpty, seen.insert(tag).inserted {
                    tags.append(tag)
                }
            }
            book.tags = tags
        }
        // 简介：先定位 "mod book-intro" 再取其中的 class="bd"（避开 bd column-2 的章节列表）
        if let range = html.range(of: "mod book-intro") {
            let tail = String(html[range.lowerBound...])
            if let bd = firstGroup("class=\"bd\"[^>]*>(.*?)</div>", in: tail) {
                book.intro = stripTags(bd)
            }
        }
        if book.intro.isEmpty {
            // 兜底：全文第 3 个 class="bd" 块
            if let re = try? NSRegularExpression(pattern: "<div[^>]*class=\"bd\"[^>]*>(.*?)</div>",
                                                 options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let ns = html as NSString
                let matches = re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
                if matches.count > 2 {
                    book.intro = stripTags(ns.substring(with: matches[2].range(at: 1)))
                }
            }
        }
        return book
    }

    // MARK: - 目录
    /// 解析章节链接 /区/书号/章号.html，按章号升序去重
    static func parseChapters(_ html: String, baseURL: URL?) -> [Chapter] {
        guard let re = try? NSRegularExpression(
            pattern: "href=\"([^\"#]*?/(\\d+)\\.html)\"[^>]*>\\s*([^<]*)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [Chapter] = []
        re.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m, m.numberOfRanges > 3 else { return }
            let href = ns.substring(with: m.range(at: 1))
            let num = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let title = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            // 归一成相对路径
            let path: String
            if href.hasPrefix("http"), let u = URL(string: href) {
                path = u.path
            } else if href.hasPrefix("/") {
                path = href
            } else if let base = baseURL {
                path = URL(string: href, relativeTo: base)?.path ?? href
            } else {
                path = href
            }
            if !seen.contains(path) {
                seen.insert(path)
                out.append(Chapter(number: num, name: title, path: path))
            }
        }
        out.sort { $0.number < $1.number }
        return out
    }

    // MARK: - 快照测试接口

    /// 解析搜索页（返回简化视图）
    static func parseSearch(_ html: String) -> [(title: String, path: String)] {
        let books = parseBookList(html)
        return books.map { (title: $0.title, path: $0.path) }
    }

    /// 解析目录页（返回简化视图）
    static func parseTOC(_ html: String) -> [(name: String, path: String)] {
        let chapters = parseChapters(html, baseURL: nil)
        return chapters.map { (name: $0.name, path: $0.path) }
    }

    /// 解析正文页（返回纯文本）
    static func parseContent(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 正文分段（同一章的后续分页）

    /// 内联脚本里「四个引号数字」的调用形状：第 3、4 个数即后续段地址里的两个数字。
    ///
    /// 与书源规则同形：`('a','b','<p1>','<p2>')` → `<p1>_<p2>.html`。
    /// 只认「四个」引号数字（与规则里的形状一致），放宽会误收无关脚本。
    private static let segmentCallPattern =
        "\\(\\s*['\"](\\d+)['\"]\\s*,\\s*['\"](\\d+)['\"]\\s*,\\s*['\"](\\d+)['\"]\\s*,\\s*['\"](\\d+)['\"]\\s*\\)"

    /// 独立的相对引用形状：`<数字>_<数字>.html`，且**前面不是** `/`、词字符、`.`、`-`、`_`。
    /// 前导 `/` 的绝对路径（分类导航等同形链接）因此天然落选，不会被当成后续段。
    private static let segmentLinkPattern = "(?:^|[^/\\w.\\-])(\\d+)_(\\d+)\\.html"

    /// 从正文页里取「下一段」的相对文件名（**只按形状**匹配，零站点字面量）。
    ///
    /// 站点把同一章的正文切成多个 HTML 分页，后续段地址形如 `<数字>_<数字>.html`，
    /// 且**相对**当前章节页（没有前导 `/`）。页面里它有两种形状，两种都收：
    /// 1. 内联脚本的四元引号数字调用 —— 取第 3、4 个数拼出地址（书源规则即此形状）；
    /// 2. 直接的相对引用 `<数字>_<数字>.html`。
    ///
    /// 两种都取不到返回 nil：**没有后续段是常态，不是错误**，调用方据此收尾。
    static func nextSegmentReference(in html: String) -> String? {
        if let filename = segmentFilename(pattern: segmentCallPattern, nameGroup: 3, pageGroup: 4, in: html) {
            return filename
        }
        return segmentFilename(pattern: segmentLinkPattern, nameGroup: 1, pageGroup: 2, in: html)
    }

    /// 按给定正则取「名称数字 + 页码数字」，拼成 `<名称>_<页码>.html`。
    private static func segmentFilename(pattern: String, nameGroup: Int, pageGroup: Int,
                                        in html: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > max(nameGroup, pageGroup) else { return nil }
        let name = ns.substring(with: m.range(at: nameGroup))
        let page = ns.substring(with: m.range(at: pageGroup))
        return "\(name)_\(page).html"
    }
}
