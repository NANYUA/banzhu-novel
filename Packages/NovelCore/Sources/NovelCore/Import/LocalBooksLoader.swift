import Dependencies
import Foundation
import SwiftData

/// 本地导入书在「本地」列表里的一行。
///
/// 只带列表要显示的东西：书名 / 作者 / 章节数 / 读到哪一章。
/// 阅读落点（`lastReadChapterPath` / `lastReadOffset`）不在这里 ——
/// 打开阅读页走的是书架那条 `ReadingTargetLoader` 路径，与下载队列用同一条入口。
public struct LocalBookRow: Equatable, Sendable, Identifiable {
    public let bookPath: String
    public let title: String
    public let author: String
    public let chapterCount: Int
    public let lastReadChapterName: String?

    public var id: String {
        bookPath
    }

    public init(
        bookPath: String,
        title: String,
        author: String,
        chapterCount: Int,
        lastReadChapterName: String?
    ) {
        self.bookPath = bookPath
        self.title = title
        self.author = author
        self.chapterCount = chapterCount
        self.lastReadChapterName = lastReadChapterName
    }
}

/// 本地导入书加载器（依赖）。
///
/// 「本地」页原先只有下载队列（`DownloadTask` 派生），导入的书没有任何 `DownloadTask`
/// ⇒ 导完在「本地」里根本看不见（owner 2026-10-17 真机反馈「本地导入的书籍也要出现在本地列表中」）。
/// 这里按 `LocalBookPath.isLocal(_:)` 从 `BookRecord` 里捞出本地书，供「本地」页多渲染一段。
///
/// 判据**只能**用路径前缀：`BookRecord` 上没有来源标记（零 schema 迁移是当时的取舍），
/// 用「没有封面 / host 为空」之类的间接判据会把站点书误判成本地书。
public struct LocalBooksLoader: Sendable {
    public var load: @Sendable () async -> [LocalBookRow]

    public init(load: @escaping @Sendable () async -> [LocalBookRow]) {
        self.load = load
    }
}

extension DependencyValues {
    /// 本地导入书加载器。测试里用 `withDependencies { $0.localBooksLoader.load = { … } }` 替换。
    public var localBooksLoader: LocalBooksLoader {
        get { self[LocalBooksLoaderKey.self] }
        set { self[LocalBooksLoaderKey.self] = newValue }
    }

    private enum LocalBooksLoaderKey: DependencyKey {
        static let liveValue = LocalBooksLoader {
            await LocalBooksLoaderLive.load()
        }

        /// 测试默认值：没有本地书。读类依赖给空值（不会静默读到真库）。
        static let testValue = LocalBooksLoader {
            []
        }
    }
}

/// 真实来源：SwiftData。`@MainActor` 的理由与 `ShelfLoaderLive` 相同。
@MainActor
public enum LocalBooksLoaderLive {
    public static func load() -> [LocalBookRow] {
        guard let container = try? NovelStore.makeContainer() else { return [] }
        return rows(from: ModelContext(container))
    }

    /// 供测试用内存容器直接取（不落盘）。
    public static func rows(from context: ModelContext) -> [LocalBookRow] {
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        return books
            .filter { LocalBookPath.isLocal($0.bookPath) }
            .sorted { $0.addedAt > $1.addedAt }
            .map { book in
                LocalBookRow(
                    bookPath: book.bookPath,
                    title: book.title,
                    author: book.author,
                    chapterCount: book.latestChapterCount,
                    lastReadChapterName: book.lastReadChapterName
                )
            }
    }
}
