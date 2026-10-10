import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 未上架书的远端兜底结果：详情 + 目录。
///
/// 只有**还没进书架**的书才需要它 —— 那本书本地既没有 `BookRecord` 也没有
/// `ChapterRecord`，详情页首屏什么也读不到。
struct BookPreview: Equatable, Sendable {
    let detail: BookDetail
    let chapters: [ChapterItem]
}

/// 书籍详情加载器（依赖）。
///
/// 详情页要的详情与目录有两个来源，都收在这一个依赖里 —— 两条入口（书架 / 搜索）走的是
/// 同一条加载路径，不给它们各留一个读法：
/// - `load`：**本地快照**。命中 `BookRecord`（只有加入书架才会写入）就是「已在书架」，
///   读不到就是没加过：这个 `nil` 是界面「加入书架 / 移出书架」的唯一判据。
/// - `preview`：**未上架时的远端兜底**。搜索入口点进来的书还没落库，没有它，
///   详情页只能显示搜索列表带的回退字段（列表页没有简介）且目录为空，
///   连「开始阅读」都出不来 —— 真机缺陷「搜索进详情没简介、没章节、进不了阅读」的成因。
struct BookDetailLoader: Sendable {
    var load: @Sendable (String) async throws -> BookDetail?

    /// 未上架时的远端兜底。返回 `nil` 表示这次不兜底（测试默认值即如此）。
    var preview: @Sendable (String) async throws -> BookPreview? = { _ in nil }
}

extension DependencyValues {
    /// 详情加载器。测试里用 `withDependencies { $0.bookDetailLoader.load = { … } }` 替换。
    var bookDetailLoader: BookDetailLoader {
        get { self[BookDetailLoaderKey.self] }
        set { self[BookDetailLoaderKey.self] = newValue }
    }

    private enum BookDetailLoaderKey: DependencyKey {
        static let liveValue = BookDetailLoader(
            load: { bookPath in try await BookDetailLoaderLive.load(bookPath: bookPath) },
            preview: { bookPath in try await BookDetailLoaderLive.preview(bookPath: bookPath) }
        )

        /// 测试默认值：读不到本地记录、也不联网 —— 忘记注入桩的测试不会意外读库或联网。
        static let testValue = BookDetailLoader { _ in nil }
    }
}

/// 真实实现：本地读 `BookRecord`；未上架时再联网取详情 + 目录。
@MainActor
private enum BookDetailLoaderLive {
    static func load(bookPath: String) throws -> BookDetail? {
        let context = try ModelContext(NovelStore.makeContainer())
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return BookDetail(
            bookPath: record.bookPath,
            title: record.title,
            author: record.author,
            coverUrl: record.coverUrl,
            intro: record.intro,
            status: record.status,
            category: record.category,
            tags: record.tags
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            wordCount: record.wordCount,
            lastChapter: record.latestChapterName ?? "",
            lastUpdated: record.lastUpdated,
            // 阅读位置只存在本地记录里 —— 「继续阅读」全靠这两个字段。
            lastReadChapterPath: record.lastReadChapterPath,
            lastReadChapterName: record.lastReadChapterName
        )
    }

    /// 未上架书的远端兜底：详情 + 目录，**不落库**。
    ///
    /// 不落库是有意的：看一眼详情不该把书塞进书架（那会改用户的书架内容）。
    /// 目录行一律 `hasLocalText: false, isDownloaded: false` —— 目录是刚拉下来的，
    /// 本地还没有正文，也不是用户下载（`isDownloaded` 只认 `ChapterRecord.source`）。
    static func preview(bookPath: String) async throws -> BookPreview {
        let book = try await NovelEngine.shared.bookInfo(path: bookPath)
        let chapters = try await NovelEngine.shared.chapters(bookPath: bookPath)
        return BookPreview(
            detail: BookDetail(book: book),
            chapters: chapters.map {
                ChapterItem(
                    number: $0.number,
                    name: $0.name,
                    path: $0.path,
                    hasLocalText: false,
                    isDownloaded: false
                )
            }
        )
    }
}
