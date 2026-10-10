import Dependencies
import Foundation
import SwiftData

/// 按书路径批量取封面地址（`BookRecord.coverUrl`）。
///
/// ## 为什么需要它
/// 本地（下载）页的书卡是从 `DownloadTaskSnapshot` 聚合出来的，而快照里**没有** `coverUrl`
/// （它只有 `bookPath` / `bookTitle` / 章节信息）⇒ 书卡原先只能画占位块。
/// 封面的真值在 `BookRecord.coverUrl` 上 —— 只有「已加入书架」的书才有这条记录。
///
/// ## 为什么一次查一批，而不是逐卡查
/// 书卡在 `List` 里滚动；逐卡同步查库会在滚动过程中反复读库（重活）。
/// 这里一次 `fetch` 拿全部 `BookRecord`，再在内存里挑出请求的那几本 ——
/// **读库次数与队列长度无关**，且与渲染解耦（由页面在 `bookPaths` 变化时拉一次）。
///
/// ## 不新增 SwiftData 字段
/// 只是读既有的 `BookRecord.coverUrl`，schema 一行不动。
public struct BookCoverLoader: Sendable {
    /// 入参是一批 `bookPath`，返回 `bookPath → coverUrl`。
    ///
    /// 库里没有这本书、或它的 `coverUrl` 为空时**不出现在结果里** ——
    /// 调用方据此回退到占位块（「查不到」与「空串」在界面上是同一种处理）。
    public var load: @Sendable ([String]) async throws -> [String: String]

    public init(load: @escaping @Sendable ([String]) async throws -> [String: String]) {
        self.load = load
    }
}

extension DependencyValues {
    /// 书封面加载器。测试里用 `withDependencies { $0.bookCoverLoader.load = { … } }` 替换。
    public var bookCoverLoader: BookCoverLoader {
        get { self[BookCoverLoaderKey.self] }
        set { self[BookCoverLoaderKey.self] = newValue }
    }

    private enum BookCoverLoaderKey: DependencyKey {
        static let liveValue = BookCoverLoader { bookPaths in
            try await BookCoverLoaderLive.load(bookPaths: bookPaths)
        }

        /// 测试默认值：查不到封面 ⇒ 全部走占位块，避免忘记注入桩的测试意外读真库。
        static let testValue = BookCoverLoader { _ in [:] }
    }
}

/// 真实实现：一次 `fetch` 全部书目，在内存里挑出要的那几本。
@MainActor
private enum BookCoverLoaderLive {
    static func load(bookPaths: [String]) throws -> [String: String] {
        let wanted = Set(bookPaths)
        guard !wanted.isEmpty else { return [:] }

        let context = try ModelContext(NovelStore.makeContainer())
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []

        var covers: [String: String] = [:]
        for book in books where wanted.contains(book.bookPath) {
            guard !book.coverUrl.isEmpty else { continue }
            covers[book.bookPath] = book.coverUrl
        }
        return covers
    }
}
