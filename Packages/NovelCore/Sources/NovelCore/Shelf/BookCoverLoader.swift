import Dependencies
import Foundation
import SwiftData

/// 书库里一本书的元信息（本地（下载）页书卡的自愈来源）。
///
/// ## 为什么需要它
/// 本地页的书卡是从 `DownloadTaskSnapshot` 聚合出来的，而快照里只有
/// `bookPath` / `bookTitle` / 章节信息 —— **没有作者**，封面的真值也不在快照里。
/// 更麻烦的是快照的 `bookTitle` 可能是**历史脏数据**：早期 `downloadCurrentChapter`
/// 曾给 `DownloadChapterRequest` 传过空串（现已修），那批任务落库后书名就是 `""`，
/// 书卡据此渲染就会「看不到书名」。
///
/// 书名 / 作者 / 封面的真值都在 `BookRecord` 上，故由本加载器**一次读库**一并带回，
/// 调用方（书卡）据此显示 —— 历史脏数据在**显示时自愈**，且以后不会再空白。
///
/// ## 为什么一次查一批，而不是逐卡查
/// 书卡在 `List` 里滚动；逐卡同步查库会在滚动过程中反复读库（重活）。
/// 这里一次 `fetch` 拿全部 `BookRecord`，再在内存里挑出请求的那几本 ——
/// **读库次数与队列长度无关**，且与渲染解耦（由页面在 `bookPaths` 变化时拉一次）。
///
/// ## 不新增 SwiftData 字段
/// 只是读既有的 `BookRecord`，schema 一行不动。
///
/// ⚠️ 文件名沿用历史名 `BookCoverLoader.swift`；类型已改名为 `BookLibraryMetaLoader`
/// （现在同时返回封面 / 书名 / 作者）。**刻意不改文件名**：本项目的 API 推送工具按路径校验
/// blob，重命名在 diff 里表现为「删除 + 新增」，会让推送失败 ⇒ 提交里不许出现删除或重命名文件。
public struct BookLibraryMeta: Equatable, Sendable {
    public init(title: String, author: String, coverUrl: String) {
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
    }

    /// `BookRecord.title`。**可能为空串**（书库里的字段是非可选 `String`）——
    /// 「空串」与「没有」由调用方统一按「不显示」处理，本类型不做裁剪。
    public let title: String
    /// `BookRecord.author`。同上，可能为空串。
    public let author: String
    /// `BookRecord.coverUrl`。同上；空串由书卡回退到占位块。
    public let coverUrl: String
}

/// 按书路径批量取书库元信息（`BookRecord` 的书名 / 作者 / 封面地址）。
public struct BookLibraryMetaLoader: Sendable {
    /// 入参是一批 `bookPath`，返回 `bookPath → BookLibraryMeta`。
    ///
    /// 库里**没有**这本书时**不出现在结果里** —— 调用方据此回退到任务快照里的书名
    /// （可以下载一本没加入书架的书 ⇒ 没有 `BookRecord`）。
    /// 书存在但某个字段是空串时**照常返回**（是否显示由书卡决定）。
    public var load: @Sendable ([String]) async throws -> [String: BookLibraryMeta]

    public init(load: @escaping @Sendable ([String]) async throws -> [String: BookLibraryMeta]) {
        self.load = load
    }
}

extension DependencyValues {
    /// 书库元信息加载器。测试里用 `withDependencies { $0.bookLibraryMetaLoader.load = { … } }` 替换。
    public var bookLibraryMetaLoader: BookLibraryMetaLoader {
        get { self[BookLibraryMetaLoaderKey.self] }
        set { self[BookLibraryMetaLoaderKey.self] = newValue }
    }

    private enum BookLibraryMetaLoaderKey: DependencyKey {
        static let liveValue = BookLibraryMetaLoader { bookPaths in
            try await BookLibraryMetaLoaderLive.load(bookPaths: bookPaths)
        }

        /// 测试默认值：查不到元信息 ⇒ 书名回退任务快照、封面走占位块，
        /// 避免忘记注入桩的测试意外读真库。
        static let testValue = BookLibraryMetaLoader { _ in [:] }
    }
}

/// 真实实现：一次 `fetch` 全部书目，在内存里挑出要的那几本。
@MainActor
private enum BookLibraryMetaLoaderLive {
    static func load(bookPaths: [String]) throws -> [String: BookLibraryMeta] {
        let wanted = Set(bookPaths)
        guard !wanted.isEmpty else { return [:] }

        let context = try ModelContext(NovelStore.makeContainer())
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []

        var metas: [String: BookLibraryMeta] = [:]
        for book in books where wanted.contains(book.bookPath) {
            metas[book.bookPath] = BookLibraryMeta(
                title: book.title,
                author: book.author,
                coverUrl: book.coverUrl
            )
        }
        return metas
    }
}
