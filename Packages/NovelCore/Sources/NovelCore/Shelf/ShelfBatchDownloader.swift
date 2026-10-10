import Dependencies
import Foundation
import SwiftData

/// 把书架选中的书展开成整本下载请求（依赖）。
///
/// 书架行只有书的投影，章节清单在 SwiftData 里；
/// reducer 通过这个依赖拿到 `DownloadChapterRequest`，再由界面交给下载队列。
struct ShelfBatchDownloader: Sendable {
    var prepare: @Sendable ([String]) async throws -> [DownloadChapterRequest]
}

extension DependencyValues {
    var shelfBatchDownloader: ShelfBatchDownloader {
        get { self[ShelfBatchDownloaderKey.self] }
        set { self[ShelfBatchDownloaderKey.self] = newValue }
    }

    private enum ShelfBatchDownloaderKey: DependencyKey {
        static let liveValue = ShelfBatchDownloader { bookPaths in
            try await ShelfBatchDownloaderLive.prepare(bookPaths: bookPaths)
        }

        /// 测试默认值：不读库，返回空请求。
        static let testValue = ShelfBatchDownloader { _ in [] }
    }
}

/// 批量下载请求的真实实现：读目录快照，按「书 + 章号」升序展开。
@MainActor
enum ShelfBatchDownloaderLive {
    static func prepare(bookPaths: [String]) throws -> [DownloadChapterRequest] {
        guard !bookPaths.isEmpty else { return [] }
        let context = try ModelContext(NovelStore.makeContainer())

        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        let chapters = (try? context.fetch(FetchDescriptor<ChapterRecord>())) ?? []
        let titleByPath = Dictionary(
            uniqueKeysWithValues: books.map { ($0.bookPath, $0.title) }
        )

        return bookPaths.flatMap { bookPath -> [DownloadChapterRequest] in
            // 🔴 书名不许静默兜底成空串（U12）：`titleByPath` 是从 `BookRecord` 全表建的，
            // 而 `bookPaths` 只可能来自书架选中行（`selectedBookPaths` 仅由 `selectionToggled`
            // 与 `toggleSelectAllVisible` 写入，两者都取 `state.rows`，而 `rows` 唯一来自
            // `ShelfLoader.rows(from:)` 对 `BookRecord` 的全表投影）⇒ 这里查不到在构造上
            // **不可达**。真到了这一步宁可**不进队列**（`return []` 等价 `continue`）：
            // 进一个没有书名的队列，用户只会看到一张没有书名的书卡（正是本轮要修的缺陷）。
            guard let title = titleByPath[bookPath] else { return [] }

            return chapters
                .filter { $0.bookPath == bookPath }
                .sorted { $0.number < $1.number }
                .map { chapter in
                    DownloadChapterRequest(
                        bookPath: bookPath,
                        bookTitle: title,
                        chapterPath: chapter.path,
                        chapterName: chapter.name,
                        chapterNumber: chapter.number
                    )
                }
        }
    }
}
