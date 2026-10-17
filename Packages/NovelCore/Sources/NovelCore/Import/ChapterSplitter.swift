import Foundation

/// 把整本 txt 切成章节。纯函数，无 IO、无状态。
///
/// ## 判定模型：逐行 + 多规则，而不是「一条大正则」
/// 每一行都拿**启用中的规则**依次试；命中即视为标题行。另有三个护栏：
///
/// 1. **标题行长度上限**（`maxHeadingLength`）。规则里的 `.{0,30}` 只是软约束，
///    而 `第 3 章` 这种片段完全可能出现在正文段落的行尾（`builtin-1` 没有 `^` 锚点）。
///    超长行直接不参与匹配，既省时间又挡住绝大多数误判。
/// 2. **正文为空的「标题」不单独成章**。目录页会有连续几十行只有标题没有正文，
///    按标题切会切出几十个空章；丢掉它们不损失任何正文。
/// 3. **一个标题都没命中**时按字数贪心切（owner 口径：3000 字/章，章名「第 N 部分」）。
///
/// ## 首个标题之前的文字
/// 常见的是书名页 / 简介 / 广告。**并入第一章正文**而不是丢掉，也不单独成章：
/// 丢掉会损失正文，单独成章则会让每本书都多出一个没有意义的「前言」。
public enum ChapterSplitter {
    public struct Chapter: Equatable, Sendable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// 标题行的最大字数。超过它的一律当正文。
    ///
    /// 取值依据：内置规则里最宽的写法是「前缀 ≈ 10 字 + `.{0,30}`」⇒ 40 字覆盖全部合法标题。
    public static let maxHeadingLength = 40

    /// 兜底切章的字数（一个「部分」的正文长度）。
    public static let defaultFallbackChunkSize = 3000

    /// 贪心切分时，为了不把一个段落劈成两半，允许向前找换行的回退窗口。
    private static let fallbackNewlineWindow = 200

    /// 兜底下限：调用方传了 0 或负数时也不至于切出 1 个字的章。
    private static let minFallbackChunkSize = 200

    /// 切章。
    /// - Parameters:
    ///   - text: 已解码的全文（换行符可以是 `\r\n` / `\r` / `\n`）。
    ///   - rules: 用户当前的规则表；只用到 `isEnabled == true` 且正则能编译的那些。
    ///   - fallbackChunkSize: 全不命中时的兜底字数。
    /// - Returns: 按出现顺序的章节；全文只有空白时返回空数组。
    public static func split(
        text: String,
        rules: [ImportChapterRule],
        fallbackChunkSize: Int = defaultFallbackChunkSize
    ) -> [Chapter] {
        let normalized = normalizeNewlines(text)
        let regexes = rules.filter(\.isEnabled).compactMap { $0.compiled() }

        var chapters: [Chapter] = []
        var preamble: [Substring] = []
        var currentTitle: String?
        var currentLines: [Substring] = []

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let title = headingTitle(in: line, regexes: regexes) else {
                currentLines.append(line)
                continue
            }
            if let previous = currentTitle {
                append(&chapters, title: previous, lines: currentLines)
            } else {
                preamble = currentLines
            }
            currentTitle = title
            currentLines = []
        }

        if let last = currentTitle {
            append(&chapters, title: last, lines: currentLines)
        } else {
            preamble = currentLines
        }

        guard !chapters.isEmpty else {
            return fallbackChapters(from: normalized, chunkSize: fallbackChunkSize)
        }

        let lead = joined(preamble)
        if !lead.isEmpty {
            let first = chapters[0]
            chapters[0] = Chapter(title: first.title, body: lead + "\n" + first.body)
        }
        return chapters
    }

    // MARK: - 私有

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// 这一行是不是标题行；是就返回**去掉首尾空白后的整行**作为章名。
    private static func headingTitle(in line: Substring, regexes: [NSRegularExpression]) -> String? {
        // 先按长度粗筛（Substring.count 不额外分配），超长行完全不进正则。
        guard line.count <= maxHeadingLength + 8 else { return nil }
        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxHeadingLength else { return nil }
        let range = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
        for regex in regexes where regex.firstMatch(in: trimmed, range: range) != nil {
            return trimmed
        }
        return nil
    }

    /// 收一章。正文为空的直接丢（目录页的连续标题会落到这里）。
    private static func append(
        _ chapters: inout [Chapter],
        title: String,
        lines: [Substring]
    ) {
        let body = joined(lines)
        guard !body.isEmpty else { return }
        chapters.append(Chapter(title: title, body: body))
    }

    private static func joined(_ lines: [Substring]) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 兜底：按字数贪心切

    private static func fallbackChapters(from text: String, chunkSize: Int) -> [Chapter] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let size = max(minFallbackChunkSize, chunkSize)

        var chapters: [Chapter] = []
        var start = trimmed.startIndex
        while start < trimmed.endIndex {
            let hardEnd = trimmed.index(start, offsetBy: size, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            let end = hardEnd < trimmed.endIndex
                ? newlineBreak(in: trimmed, from: start, before: hardEnd)
                : hardEnd
            let body = String(trimmed[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                chapters.append(Chapter(title: "第 \(chapters.count + 1) 部分", body: body))
            }
            start = end
        }
        return chapters
    }

    /// 在 `[start, end)` 里回退到最近一个换行之后，避免把段落劈开。
    /// 找不到换行（超长单段）就按硬边界切 —— 此时宁可劈开也不能无限增长。
    private static func newlineBreak(
        in text: String,
        from start: String.Index,
        before end: String.Index
    ) -> String.Index {
        let lower = text.index(end, offsetBy: -fallbackNewlineWindow, limitedBy: start) ?? start
        guard let newline = text[lower ..< end].lastIndex(of: "\n") else { return end }
        let afterNewline = text.index(after: newline)
        // 换行恰好落在窗口起点时，切出来的前一段会几乎为空；退化成硬边界。
        guard afterNewline > start else { return end }
        return afterNewline
    }
}
