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

        return bookPaths.flatMap { bookPath in
            chapters
                .filter { $0.bookPath == bookPath }
                .sorted { $0.number < $1.number }
                .map { chapter in
                    DownloadChapterRequest(
                        bookPath: bookPath,
                        bookTitle: titleByPath[bookPath] ?? "",
                        chapterPath: chapter.path,
                        chapterName: chapter.name,
                        chapterNumber: chapter.number
                    )
                }
        }
    }
}
