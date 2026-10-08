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
}
