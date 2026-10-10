import Dependencies
import Foundation
import SwiftData

/// 一本书的阅读进度快照。
///
/// `offset` 是**字符偏移**（数据契约 ③），不是页码 ——
/// 字号 / 行距 / 页边距都会改变分页，只有字符偏移能唯一定位到同一处文字。
public struct ReadingProgress: Equatable, Sendable {
    public let chapterPath: String
    public let chapterName: String
    public let offset: Int

    public init(chapterPath: String, chapterName: String, offset: Int) {
        self.chapterPath = chapterPath
        self.chapterName = chapterName
        self.offset = offset
    }
}

/// 阅读进度读写依赖。
///
/// ## 为什么读和写必须在同一处
/// `lastReadAt` 既是书架排序键，也是 LRU 淘汰的最旧优先依据；
/// 正文加载成功后必须刷新它，否则淘汰排序会一直停留在旧值。
/// 而「上次看到哪一章、章内哪个偏移」正是书架 / 本地 / 分组单点进书时要恢复的位置
/// —— 只有写没有读，进度就永远回不到阅读页。
public struct ReadingProgressStore: Sendable {
    /// 记录一章已开始阅读。
    public var markRead: @Sendable (String, Int, Date) async throws -> Void

    /// 读回某本书的阅读进度；没有记录（或记录不完整）返回 nil。
    ///
    /// 入参是 **`bookPath`**（`BookRecord.bookPath`，形如 `/49/49034/`），
    /// 不是章节路径 —— 一本书只有一个「上次看到哪」。
    public var load: @Sendable (String) async throws -> ReadingProgress?

    public init(
        markRead: @escaping @Sendable (String, Int, Date) async throws -> Void,
        load: @escaping @Sendable (String) async throws -> ReadingProgress?
    ) {
        self.markRead = markRead
        self.load = load
    }
}

extension DependencyValues {
    public var readingProgressStore: ReadingProgressStore {
        get { self[ReadingProgressStoreKey.self] }
        set { self[ReadingProgressStoreKey.self] = newValue }
    }

    private enum ReadingProgressStoreKey: DependencyKey {
        static let liveValue = ReadingProgressStore(
            markRead: { chapterPath, offset, date in
                try await ReadingProgressStoreLive.markRead(
                    chapterPath: chapterPath,
                    offset: offset,
                    date: date
                )
            },
            load: { bookPath in
                try await ReadingProgressStoreLive.load(bookPath: bookPath)
            }
        )

        /// 测试默认值：不读不写，避免忘记注入桩的测试意外读写真库。
        static let testValue = ReadingProgressStore(
            markRead: { _, _, _ in },
            load: { _ in nil }
        )
    }
}

@MainActor
enum ReadingProgressStoreLive {
    static func markRead(chapterPath: String, offset: Int, date: Date) throws {
        let context = try ModelContext(NovelStore.makeContainer())
        try markRead(chapterPath: chapterPath, offset: offset, date: date, in: context)
    }

    /// 可注入容器的实现，供测试直接验证落盘字段（不碰真实沙盒）。
    ///
    /// ⚠️ `offset` **原样落盘**：曾把传入值丢掉、恒写 0 ⇒ 恢复位置永远回到章首。
    static func markRead(
        chapterPath: String,
        offset: Int,
        date: Date,
        in context: ModelContext
    ) throws {
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

    static func load(bookPath: String) throws -> ReadingProgress? {
        let context = try ModelContext(NovelStore.makeContainer())
        return try load(bookPath: bookPath, in: context)
    }

    /// 可注入容器的实现，供测试直接验证读回规则（不碰真实沙盒）。
    static func load(bookPath: String, in context: ModelContext) throws -> ReadingProgress? {
        guard let book = try fetchBook(bookPath: bookPath, in: context) else { return nil }
        return progress(of: book)
    }

    /// 「有记录」= 章节路径与章名**都非空**（`lastReadOffset` 允许为 0）。
    ///
    /// 只有半条记录（缺路径或缺章名）时返回 nil：拿它去定位会打开错误的章节，
    /// 不如退化成「从未看过 ⇒ 第一章第一页」。
    private static func progress(of book: BookRecord) -> ReadingProgress? {
        guard let chapterPath = book.lastReadChapterPath, !chapterPath.isEmpty,
              let chapterName = book.lastReadChapterName, !chapterName.isEmpty
        else { return nil }
        return ReadingProgress(
            chapterPath: chapterPath,
            chapterName: chapterName,
            offset: book.lastReadOffset
        )
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
