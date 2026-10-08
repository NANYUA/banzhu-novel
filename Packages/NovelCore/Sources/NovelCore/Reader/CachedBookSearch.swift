import Dependencies
import Foundation
import SwiftData

/// 全本已缓存内容的搜索结果。
public struct CachedSearchHit: Equatable, Identifiable, Sendable {
    public init(
        chapterNumber: Int,
        chapterName: String,
        chapterPath: String,
        snippet: String
    ) {
        self.chapterNumber = chapterNumber
        self.chapterName = chapterName
        self.chapterPath = chapterPath
        self.snippet = snippet
    }

    public var id: String {
        chapterPath
    }

    public let chapterNumber: Int
    public let chapterName: String
    public let chapterPath: String
    public let snippet: String
}

/// 在本地已缓存正文中搜索，不联网。
public struct CachedBookSearch: Sendable {
    public var search: @Sendable (String, String) async throws -> [CachedSearchHit]

    public init(search: @escaping @Sendable (String, String) async throws -> [CachedSearchHit]) {
        self.search = search
    }
}

extension DependencyValues {
    public var cachedBookSearch: CachedBookSearch {
        get { self[CachedBookSearchKey.self] }
        set { self[CachedBookSearchKey.self] = newValue }
    }

    private enum CachedBookSearchKey: DependencyKey {
        static let liveValue = CachedBookSearch { bookPath, query in
            try await CachedBookSearchLive.search(bookPath: bookPath, query: query)
        }

        static let testValue = CachedBookSearch { _, _ in [] }
    }
}

@MainActor
private enum CachedBookSearchLive {
    static func search(bookPath: String, query: String) throws -> [CachedSearchHit] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let context = try ModelContext(NovelStore.makeContainer())
        let descriptor = FetchDescriptor<ChapterRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        let chapters = try context.fetch(descriptor).sorted { $0.number < $1.number }
        var hits: [CachedSearchHit] = []
        for chapter in chapters where chapter.hasLocalText {
            guard let text = try? NovelStore.loadChapterText(
                bookPath: chapter.bookPath,
                number: chapter.number
            ) else { continue }
            guard let range = text.range(of: normalized, options: [.caseInsensitive]) else {
                continue
            }
            hits.append(
                CachedSearchHit(
                    chapterNumber: chapter.number,
                    chapterName: chapter.name,
                    chapterPath: chapter.path,
                    snippet: snippet(text: text, range: range)
                )
            )
        }
        return hits
    }

    static func snippet(text: String, range: Range<String.Index>) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex)
            ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 36, limitedBy: text.endIndex)
            ?? text.endIndex
        return "…" + text[lower ..< upper].replacingOccurrences(of: "\n", with: " ") + "…"
    }
}
