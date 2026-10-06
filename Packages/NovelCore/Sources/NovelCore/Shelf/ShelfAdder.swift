import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 把一本书加入书架（依赖）。
///
/// ## 为什么单独抽成一个依赖，而不是并进 ShelfLoader
/// 「读书架」和「写书架」的生命周期完全不同：
/// - 读：视图出现时拉一次，用不着网络
/// - 写：要**联网**抓详情 + 目录，可能失败、可能被盾拦，还会写文件
///
/// 分开后测试可以只对其中一边注入桩：
/// 测 reducer 时不需要为了「读」而准备「写」的网络桩。
struct ShelfAdder: Sendable {
    /// 加入书架。返回入库后的行（供视图立刻显示）。
    ///
    /// - Parameter book: 引擎返回的书（至少含 path / title）
    /// - Returns: 入库后的 `ShelfRow`
    /// - Throws: `ShelfAdderError.alreadyExists` 或网络/存储错误
    var add: @Sendable (Book) async throws -> ShelfRow
}

/// 加入书架时可能出现的**业务错误**（区别于网络错误）。
public enum ShelfAdderError: LocalizedError, Equatable {
    /// 这本书已经在书架里了。
    /// 🔴 单独成错而不是静默成功：用户需要知道「加过了」，否则会以为没生效而反复点。
    case alreadyExists(title: String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyExists(title):
            return "《\(title)》已经在书架里了。"
        }
    }
}

extension DependencyValues {
    /// 加入书架。测试里用 `withDependencies { $0.shelfAdder.add = { … } }` 替换。
    var shelfAdder: ShelfAdder {
        get { self[ShelfAdderKey.self] }
        set { self[ShelfAdderKey.self] = newValue }
    }

    private enum ShelfAdderKey: DependencyKey {
        static let liveValue = ShelfAdder { book in
            try await ShelfAdderLive.add(book)
        }

        /// 测试默认值：直接抛错，避免忘记注入桩的测试「静默成功」。
        /// 与 `ShelfLoader` 的空列表默认值不同 —— 写入操作失败要吵闹，读取操作为空要安静。
        static let testValue = ShelfAdder { _ in
            throw ShelfAdderError.alreadyExists(title: "(未注入桩)")
        }
    }
}

/// 真实实现：抓目录 → 落库。
@MainActor
enum ShelfAdderLive {
    static func add(_ book: Book) async throws -> ShelfRow {
        let container = try NovelStore.makeContainer()
        let context = ModelContext(container)

        // ── 1. 查重 ──────────────────────────────────────────────
        // 以 bookPath 为唯一键（全局唯一）。
        let path = book.path
        var existing = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == path }
        )
        existing.fetchLimit = 1
        if let found = try? context.fetch(existing).first {
            throw ShelfAdderError.alreadyExists(title: found.title)
        }

        // ── 2. 抓目录（联网） ────────────────────────────────────
        // 失败就直接抛，不落库 —— 半成品条目（有书没目录）会让书架显示「0 章」，
        // 用户点进去才发现是坏的，比直接失败更糟。
        let chapters = try await NovelEngine.shared.chapters(bookPath: book.path)

        // ── 3. 落库 ──────────────────────────────────────────────
        let record = BookRecord(
            bookPath: book.path,
            title: book.title,
            author: book.author,
            intro: book.intro,
            coverUrl: book.coverUrl,
            wordCount: book.wordCount
        )
        // 目录快照：需求要求离线也能显示「最新章节」与「未读章数」
        record.latestChapterName = chapters.last?.name
        record.latestChapterCount = chapters.count
        context.insert(record)

        for chapter in chapters {
            let chapterRecord = ChapterRecord(
                bookPath: book.path,
                number: chapter.number,
                name: chapter.name,
                path: chapter.path
            )
            context.insert(chapterRecord)
        }

        try context.save()

        return ShelfRow(
            bookPath: record.bookPath,
            title: record.title,
            author: record.author,
            coverUrl: record.coverUrl,
            lastReadChapterName: nil,
            latestChapterName: record.latestChapterName,
            unreadCount: chapters.count,
            lastReadAt: nil
        )
    }
}
