import Dependencies
import Foundation
import SwiftData

/// 书架数据加载器（依赖）。
///
/// ## 为什么把 IO 收进依赖，而不是让 reducer 直接 fetch
/// reducer 若直接碰 `ModelContext`，测试就得先建真数据库。
/// D2 选 TCA 的四条理由里有一条是「**喂一串 Action 断言状态，不用启动界面**」——
/// 把 IO 藏进依赖后，测试用 `withDependencies` 换成内存桩，
/// 断言的仍然是**完整的状态迁移**，而不是「数据库恰好返回了什么」。
struct ShelfLoader: Sendable {
    /// 取整个书架。已按 `ShelfOrder` 排好序。
    var load: @Sendable () async throws -> [ShelfRow]
}

extension DependencyValues {
    /// 书架加载器。测试里用 `withDependencies { $0.shelfLoader.load = { … } }` 替换。
    var shelfLoader: ShelfLoader {
        get { self[ShelfLoaderKey.self] }
        set { self[ShelfLoaderKey.self] = newValue }
    }

    private enum ShelfLoaderKey: DependencyKey {
        /// 正式实现：走 SwiftData
        static let liveValue = ShelfLoader {
            try await ShelfLoaderLive.load()
        }

        /// 测试默认值：空书架。
        /// 不做成 `liveValue` 的替身，是为了让**忘记注入桩**的测试安静地拿到空列表，
        /// 而不是意外读到真库里的数据。
        static let testValue = ShelfLoader {
            []
        }
    }
}

/// 书架数据的真实来源：SwiftData。
///
/// 标 `@MainActor` 是因为 SwiftData 的 `ModelContext` 面向主线程使用，
/// 而依赖的签名是 `@Sendable` 的 —— 让调用方自己处理线程是错的做法。
@MainActor
enum ShelfLoaderLive {
    static func load() throws -> [ShelfRow] {
        let container = try NovelStore.makeContainer()
        return rows(from: ModelContext(container))
    }

    /// 读取全部书并投影成 `ShelfRow`。
    ///
    /// - Note: 排序放在 Swift 侧而非 `FetchDescriptor.sortBy`，理由见 `ShelfOrder`。
    static func rows(from context: ModelContext) -> [ShelfRow] {
        // 不加 sortBy：排序统一由 ShelfOrder 负责，避免两处规则打架
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        return books.sorted(by: ShelfOrder.isBefore).map { book in
            ShelfRow(
                bookPath: book.bookPath,
                title: book.title,
                author: book.author,
                coverUrl: book.coverUrl,
                lastReadChapterName: book.lastReadChapterName,
                latestChapterName: book.latestChapterName,
                unreadCount: unreadCount(of: book, in: context),
                lastReadAt: book.lastReadAt
            )
        }
    }

    /// 未读章数 = 快照总章数 − 已读到的章序号。
    ///
    /// 查不到那一章时（进度指向的章节已被删除、或目录快照被重建过）
    /// 退化为「全部未读」—— 宁可多报也不虚报，用户点进去一看就知道。
    private static func unreadCount(of book: BookRecord, in context: ModelContext) -> Int {
        guard let lastPath = book.lastReadChapterPath else {
            return book.latestChapterCount
        }
        let bookPath = book.bookPath
        var descriptor = FetchDescriptor<ChapterRecord>(
            predicate: #Predicate { $0.path == lastPath && $0.bookPath == bookPath }
        )
        descriptor.fetchLimit = 1
        guard let chapter = try? context.fetch(descriptor).first else {
            return book.latestChapterCount
        }
        return book.unreadCount(readChapterIndex: chapter.number)
    }
}
