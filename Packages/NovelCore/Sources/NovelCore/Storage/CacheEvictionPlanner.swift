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
/// - 🔴 **已读章节与当前预取窗口内的章节也不得淘汰**（owner 2026-10-11 口径）：
///   只允许淘汰 `number > 已读章号 + precacheCount` 的 `.cached` 章节 ——
///   即“以前预取过、后来把预缓存章数调小、如今落在窗口之外”的陈旧缓存。
///   ⇒ 正在读的那一本天然全保：它的缓存要么已读、要么就在窗口内。
enum CacheEvictionPlanner {
    static func plan(
        books: [BookRecord],
        chapters: [ChapterRecord],
        maxCachedBooks: Int,
        precacheCount: Int
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
            .compactMap { book in
                evictionPlan(for: book, chapters: chapters, precacheCount: precacheCount)
            }
    }

    /// 把一本书折算成淘汰计划；**没有任何可淘汰章节时返回 `nil`**（不产出空计划）。
    ///
    /// ⚠️ 返回 `nil` 而不是空计划，是为了让“这本书的缓存全部要保留”这件事
    /// 在结果里显式可见：调用方（与测试）据此知道**本轮实际没有动这本书**。
    private static func evictionPlan(
        for book: BookRecord,
        chapters: [ChapterRecord],
        precacheCount: Int
    ) -> CacheEvictionPlan? {
        let chapterIDs = evictableChapterIDs(
            of: book,
            chapters: chapters,
            precacheCount: precacheCount
        )
        guard !chapterIDs.isEmpty else { return nil }
        return CacheEvictionPlan(bookPath: book.bookPath, chapterIDs: chapterIDs)
    }

    /// 一本书里**可淘汰**的章节 id（按章号升序）。
    private static func evictableChapterIDs(
        of book: BookRecord,
        chapters: [ChapterRecord],
        precacheCount: Int
    ) -> [String] {
        let keepThrough = readChapterNumber(of: book, chapters: chapters)
            + max(0, precacheCount)
        return chapters
            .filter {
                $0.bookPath == book.bookPath
                    && $0.source == .cached
                    && $0.number > keepThrough
            }
            .sorted { $0.number < $1.number }
            .map(\.id)
    }

    /// 这本书**已读到的章节号**（`lastReadChapterPath` 指向章节的 `number`）。
    ///
    /// ⚠️ 下面两种“查不到”一律返回 **0**（= 只有前 `precacheCount` 章受保护）：
    /// 1. `lastReadChapterPath` 为 nil / 空串（从没读过这本书）；
    /// 2. 路径在章节表里找不到（脏数据、章节表被重建）。
    ///
    /// 第 2 种之所以不取“整本当已读”，是因为那会让缓存上限**永不生效**
    /// （脏数据把整本书变成不可淘汰）；取 0 只损失“多删几章陈旧缓存”，
    /// 而“当前在读的那几章”仍由预取窗口兜住。
    private static func readChapterNumber(of book: BookRecord, chapters: [ChapterRecord]) -> Int {
        guard let path = book.lastReadChapterPath, !path.isEmpty else { return 0 }
        guard let chapter = chapters.first(where: {
            $0.bookPath == book.bookPath && $0.path == path
        }) else {
            return 0
        }
        return chapter.number
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
