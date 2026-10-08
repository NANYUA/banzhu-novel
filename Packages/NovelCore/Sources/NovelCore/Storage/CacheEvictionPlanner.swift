import Foundation

/// 一次缓存淘汰计划：按书选择，但只列出该书可淘汰的章节。
struct CacheEvictionPlan: Equatable {
    let bookPath: String
    let chapterIDs: [String]
}

/// 纯逻辑 LRU 规划器：只决定淘汰谁，不碰数据库和文件。
///
/// 需求约束：
/// - 缓存上限按“有自动缓存章节的书”计数，用户下载章节不计入
/// - 超限时淘汰最近阅读时间最早的书
/// - 淘汰按章执行，同一本书的用户下载章节必须保留
enum CacheEvictionPlanner {
    static func plan(
        books: [BookRecord],
        chapters: [ChapterRecord],
        maxCachedBooks: Int
    ) -> [CacheEvictionPlan] {
        let cachedBookPaths = Set(
            chapters
                .filter { $0.source == .cached }
                .map(\.bookPath)
        )
        let cachedBooks = books.filter { cachedBookPaths.contains($0.bookPath) }
        let excessCount = max(0, cachedBooks.count - max(0, maxCachedBooks))
        guard excessCount > 0 else { return [] }

        return cachedBooks
            .sorted(by: isColder)
            .prefix(excessCount)
            .map { book in
                let chapterIDs = chapters
                    .filter { $0.bookPath == book.bookPath && $0.source == .cached }
                    .sorted { $0.number < $1.number }
                    .map(\.id)
                return CacheEvictionPlan(bookPath: book.bookPath, chapterIDs: chapterIDs)
            }
    }

    private static func isColder(_ first: BookRecord, than second: BookRecord) -> Bool {
        let firstReadAt = first.lastReadAt ?? .distantPast
        let secondReadAt = second.lastReadAt ?? .distantPast
        if firstReadAt != secondReadAt {
            return firstReadAt < secondReadAt
        }
        if first.addedAt != second.addedAt {
            return first.addedAt < second.addedAt
        }
        return first.bookPath < second.bookPath
    }
}
