import Dependencies
import Foundation
import SwiftData

/// 阅读进度写入依赖。
///
/// `lastReadAt` 既是书架排序键，也是 LRU 淘汰的最旧优先依据；
/// 正文加载成功后必须刷新它，否则淘汰排序会一直停留在旧值。
struct ReadingProgressStore: Sendable {
    /// 记录一章已开始阅读。
    var markRead: @Sendable (String, Int, Date) async throws -> Void
}

extension DependencyValues {
    var readingProgressStore: ReadingProgressStore {
        get { self[ReadingProgressStoreKey.self] }
        set { self[ReadingProgressStoreKey.self] = newValue }
    }

    private enum ReadingProgressStoreKey: DependencyKey {
        static let liveValue = ReadingProgressStore { chapterPath, _, date in
            try await ReadingProgressStoreLive.markRead(
                chapterPath: chapterPath,
                offset: 0,
                date: date
            )
        }

        /// 测试默认值：不做持久化，避免忘记注入桩的测试意外读写真库。
        static let testValue = ReadingProgressStore { _, _, _ in }
    }
}

@MainActor
enum ReadingProgressStoreLive {
    static func markRead(chapterPath: String, offset: Int, date: Date) throws {
        let context = try ModelContext(NovelStore.makeContainer())
        let descriptor = FetchDescriptor<ChapterRecord>(
            predicate: #Predicate { $0.path == chapterPath }
        )
        guard let chapter = try context.fetch(descriptor).first else {
            return
        }
        guard let book = try fetchBook(bookPath: chapter.bookPath, in: context) else {
            return
        }

        book.lastReadChapterPath = chapter.path
        book.lastReadChapterName = chapter.name
        book.lastReadOffset = offset
        book.lastReadAt = date
        try context.save()
    }

    private static func fetchBook(
        bookPath: String,
        in context: ModelContext
    ) throws -> BookRecord? {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
