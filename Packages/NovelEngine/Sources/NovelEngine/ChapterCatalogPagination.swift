import Foundation

public enum ChapterCatalogError: LocalizedError {
    case emptyPage
    case pageLimitExceeded
    case invalidPageLink

    public var errorDescription: String? {
        switch self {
        case .emptyPage:
            return "目录页面没有可识别的章节，请重试。"
        case .pageLimitExceeded:
            return "目录分页超过安全上限，未更新已有目录。"
        case .invalidPageLink:
            return "目录分页链接异常，未更新已有目录。"
        }
    }
}

enum ChapterCatalogPagination {
    static func chapterSection(in html: String) -> String {
        let pattern = #"<(div|ul|ol|dl)\b[^>]*\bclass\s*=\s*["'][^"']*\bchapter-list\b[^"']*["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return html }
        let source = html as NSString
        let openings = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        guard let opening = openings.last else { return html }
        let tag = source.substring(with: opening.range(at: 1))
        guard let tokens = try? NSRegularExpression(pattern: "</?" + tag + "\\b[^>]*>", options: [.caseInsensitive]) else {
            return html
        }
        let start = NSMaxRange(opening.range)
        var depth = 1
        for token in tokens.matches(in: html, range: NSRange(location: start, length: source.length - start)) {
            depth += source.substring(with: token.range).hasPrefix("</") ? -1 : 1
            if depth == 0 { return source.substring(with: NSRange(location: start, length: token.range.location - start)) }
        }
        return ""
    }

    static func expectedPageCount(in html: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"第\s*\d+\s*/\s*(\d+)\s*页"#),
              let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else {
            return nil
        }
        return Int((html as NSString).substring(with: match.range(at: 1)))
    }

    static func pages(in html: String, currentURL: URL, bookURL: URL) throws -> [URL] {
        let pattern = #"<(a|option)\b([^>]*)>(.*?)</\1\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let source = html as NSString
        var pages: [URL] = []
        var seen = Set<URL>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range(at: 1)).lowercased()
            let attributes = source.substring(with: match.range(at: 2))
            let title = source.substring(with: match.range(at: 3))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let reference = attribute(tag == "a" ? "href" : "value", in: attributes) else { continue }
            let isNext = isNextLink(title: title, attributes: attributes)
            let isPageChoice = tag == "option" || Int(title) != nil
            guard isNext || isPageChoice else { continue }
            guard let url = pageURL(reference, relativeTo: currentURL, bookURL: bookURL) else {
                if isNext, !reference.isEmpty, !reference.hasPrefix("#") {
                    throw ChapterCatalogError.invalidPageLink
                }
                continue
            }
            // 数字文件名是章节，不是目录页。
            let name = url.deletingPathExtension().lastPathComponent
            if Int(name) != nil, url.pathExtension.lowercased() == "html" { continue }
            guard isNext || isNumberedPage(url, bookURL: bookURL) else { continue }
            if seen.insert(url).inserted { pages.append(url) }
        }
        return pages
    }

    static func normalized(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url.absoluteURL.standardized, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.fragment = nil
        if let items = components.queryItems {
            components.queryItems = items.sorted {
                $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
            }
        }
        return components.url
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        let pattern = #"(?:^|\s)"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        for index in 1 ..< match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return (text as NSString).substring(with: match.range(at: index))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#38;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func isNextLink(title: String, attributes: String) -> Bool {
        let relations = attribute("rel", in: attributes)?.lowercased().split(whereSeparator: { $0.isWhitespace }) ?? []
        if relations.contains("next") { return true }
        let compact = title.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return ["下页", "下一页", "後頁", "後一頁", "下一頁", "next", "nextpage", "›", "»"]
            .contains { compact == $0 || compact == $0 + ">" || compact == $0 + "&gt;" }
    }

    private static func pageURL(_ reference: String, relativeTo base: URL, bookURL: URL) -> URL? {
        guard !reference.isEmpty, !reference.hasPrefix("#"),
              let resolved = URL(string: reference, relativeTo: base),
              let url = normalized(resolved),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.scheme?.lowercased() == bookURL.scheme?.lowercased(),
              url.host?.lowercased() == bookURL.host?.lowercased(),
              url.port == bookURL.port, url.user == nil, url.password == nil else { return nil }
        let directory = bookURL.hasDirectoryPath ? bookURL : bookURL.deletingLastPathComponent()
        guard url.path == bookURL.path || url.deletingLastPathComponent().path == directory.path
            || isSiblingPage(url, bookURL: bookURL)
            || isQueryPage(url, bookURL: bookURL) else { return nil }
        return url
    }

    private static func isSiblingPage(_ url: URL, bookURL: URL) -> Bool {
        guard bookURL.hasDirectoryPath, url.hasDirectoryPath,
              url.deletingLastPathComponent().path == bookURL.deletingLastPathComponent().path else { return false }
        let prefix = bookURL.lastPathComponent + "_"
        guard url.lastPathComponent.hasPrefix(prefix),
              let page = Int(url.lastPathComponent.dropFirst(prefix.count)) else { return false }
        return page > 0
    }

    private static func isQueryPage(_ url: URL, bookURL: URL) -> Bool {
        url.path == bookURL.path && URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.contains {
            ["page", "p", "pageno", "pageindex"].contains($0.name.lowercased()) && Int($0.value ?? "") != nil
        } == true
    }

    private static func isNumberedPage(_ url: URL, bookURL: URL) -> Bool {
        if isSiblingPage(url, bookURL: bookURL) || isQueryPage(url, bookURL: bookURL) { return true }
        let name = url.lastPathComponent.lowercased()
        if name.range(of: #"^(?:index|list|catalog|toc)(?:[_-]?\d+)?\.(?:html?|php)$"#, options: .regularExpression) != nil {
            return true
        }
        guard url.path == bookURL.path,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems else { return false }
        return items.contains { item in
            ["page", "p", "pageno", "pageindex"].contains(item.name.lowercased()) && Int(item.value ?? "") != nil
        }
    }
}
