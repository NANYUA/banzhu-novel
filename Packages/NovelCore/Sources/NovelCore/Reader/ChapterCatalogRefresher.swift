import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 为已上架书籍补全目录，保留本地正文与阅读状态。
struct ChapterCatalogRefresher: Sendable {
    var refresh: @Sendable (String) async throws -> [ChapterItem]
}

enum ChapterCatalogRefreshError: LocalizedError, Equatable {
    case bookNotOnShelf
    case emptyCatalog
    case conflictingNumber(Int)
    case conflictingPath(String)
    case pendingChanges

    var errorDescription: String? {
        switch self {
        case .bookNotOnShelf:
            "这本书尚未加入书架。"
        case .emptyCatalog:
            "未获取到章节，已保留原目录。"
        case let .conflictingNumber(number):
            "章节编号 \(number) 对应多个路径，已保留原目录。"
        case let .conflictingPath(path):
            "章节路径 \(path) 对应多个编号，已保留原目录。"
        case .pendingChanges:
            "目录更新需要独立的存储上下文。"
        }
    }
}

extension DependencyValues {
    var chapterCatalogRefresher: ChapterCatalogRefresher {
        get { self[ChapterCatalogRefresherKey.self] }
        set { self[ChapterCatalogRefresherKey.self] = newValue }
    }

    private enum ChapterCatalogRefresherKey: DependencyKey {
        static let liveValue = ChapterCatalogRefresher { bookPath in
            try await ChapterCatalogRefresherLive.refresh(bookPath: bookPath)
        }

        static let testValue = ChapterCatalogRefresher { _ in
            throw ChapterCatalogRefreshError.emptyCatalog
        }
    }
}

@MainActor
enum ChapterCatalogRefresherLive {
    static func refresh(bookPath: String) async throws -> [ChapterItem] {
        try await refresh(
            bookPath: bookPath,
            load: { try await NovelEngine.shared.chapters(bookPath: $0) },
            makeContext: { try ModelContext(NovelStore.makeContainer()) }
        )
    }

    static func refresh(
        bookPath: String,
        load: (String) async throws -> [Chapter],
        makeContext: () throws -> ModelContext
    ) async throws -> [ChapterItem] {
        // 完整抓取后才建上下文，以读取等待期间更新的下载、缓存及阅读状态。
        let chapters = try await load(bookPath)
        let context = try makeContext()
        context.autosaveEnabled = false
        return try merge(chapters: chapters, bookPath: bookPath, context: context)
    }

    /// context 必须没有待保存变更；保存失败只回滚本次目录更新。
    static func merge(
        chapters: [Chapter],
        bookPath: String,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> [ChapterItem] {
        guard !context.hasChanges else { throw ChapterCatalogRefreshError.pendingChanges }
        guard !chapters.isEmpty else { throw ChapterCatalogRefreshError.emptyCatalog }
        let books = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        guard let book = try context.fetch(books).first else {
            throw ChapterCatalogRefreshError.bookNotOnShelf
        }
        let descriptor = FetchDescriptor<ChapterRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        let existing = try context.fetch(descriptor)
        try validate(chapters: chapters, existing: existing)

        let previous = CatalogRollbackState(book: book, chapters: existing)
        let merged = apply(chapters: chapters, existing: existing, bookPath: bookPath, context: context)
        book.latestChapterName = merged.last?.name
        book.latestChapterCount = merged.count
        book.lastCheckedAt = Date()
        // 登记模型属性的待处理变更，使保存失败后的回滚同步已持有的对象。
        context.processPendingChanges()
        do {
            try save(context)
        } catch {
            previous.restore(book: book, chapters: existing)
            context.processPendingChanges()
            context.rollback()
            throw error
        }
        return merged.map { ChapterItem(record: $0) }
    }

    private static func validate(chapters: [Chapter], existing: [ChapterRecord]) throws {
        var identities = CatalogIdentityIndex()
        for chapter in existing {
            try identities.insert(number: chapter.number, path: chapter.path)
        }
        for chapter in chapters {
            try identities.insert(number: chapter.number, path: chapter.path)
        }
    }

    private static func apply(
        chapters: [Chapter],
        existing: [ChapterRecord],
        bookPath: String,
        context: ModelContext
    ) -> [ChapterRecord] {
        var byPath = existing.reduce(into: [String: ChapterRecord]()) { result, chapter in
            result[chapter.path] = chapter
        }
        for chapter in chapters {
            if let record = byPath[chapter.path] {
                if !chapter.name.isEmpty {
                    record.name = chapter.name
                }
            } else {
                let record = ChapterRecord(
                    bookPath: bookPath,
                    number: chapter.number,
                    name: chapter.name,
                    path: chapter.path
                )
                context.insert(record)
                byPath[chapter.path] = record
            }
        }
        return byPath.values.sorted { $0.number < $1.number }
    }
}

private struct CatalogRollbackState {
    let latestName: String?
    let latestCount: Int
    let checkedAt: Date?
    let chapterNames: [String: String]

    init(book: BookRecord, chapters: [ChapterRecord]) {
        latestName = book.latestChapterName
        latestCount = book.latestChapterCount
        checkedAt = book.lastCheckedAt
        chapterNames = Dictionary(uniqueKeysWithValues: chapters.map { ($0.path, $0.name) })
    }

    func restore(book: BookRecord, chapters: [ChapterRecord]) {
        book.latestChapterName = latestName
        book.latestChapterCount = latestCount
        book.lastCheckedAt = checkedAt
        for chapter in chapters where chapterNames[chapter.path] != nil {
            chapter.name = chapterNames[chapter.path] ?? chapter.name
        }
    }
}


    var pathByNumber: [Int: String] = [:]
    var numberByPath: [String: Int] = [:]

    mutating func insert(number: Int, path: String) throws {
        if let existing = pathByNumber[number], existing != path {
            throw ChapterCatalogRefreshError.conflictingNumber(number)
        }
        if let existing = numberByPath[path], existing != number {
            throw ChapterCatalogRefreshError.conflictingPath(path)
        }
        pathByNumber[number] = path
        numberByPath[path] = number
    }
}
