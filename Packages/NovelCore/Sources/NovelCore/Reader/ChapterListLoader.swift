import Dependencies
import Foundation
import SwiftData

/// 章节列表加载器（依赖）。
///
/// ## 为什么收进依赖
/// 与 `ShelfLoader`/`ReaderLoader` 同理：reducer 不直接碰 SwiftData，
/// 测试用内存桩注入，断言的仍是完整的状态迁移。
struct ChapterListLoader: Sendable {
    /// 加载某本书的全部章节（按章节号升序）。
    var load: @Sendable (String) async throws -> [ChapterItem]
}

/// 目录页一行的数据（只读投影）。
///
/// 从 `ChapterRecord` 投影而来，把「本地是否有正文」翻译成界面需要的状态。
public struct ChapterItem: Equatable, Sendable, Identifiable {
    public init(
        number: Int,
        name: String,
        path: String,
        hasLocalText: Bool,
        isDownloaded: Bool
    ) {
        self.number = number
        self.name = name
        self.path = path
        self.hasLocalText = hasLocalText
        self.isDownloaded = isDownloaded
    }

    public var id: String {
        path
    }

    public let number: Int
    public let name: String
    public let path: String

    /// 本地是否有正文（缓存或下载）
    public let hasLocalText: Bool

    /// 是否用户主动下载（永久保留，不可被缓存淘汰）
    public let isDownloaded: Bool
}

extension DependencyValues {
    /// 章节列表加载器。测试里用 `withDependencies { $0.chapterListLoader.load = { … } }` 替换。
    var chapterListLoader: ChapterListLoader {
        get { self[ChapterListLoaderKey.self] }
        set { self[ChapterListLoaderKey.self] = newValue }
    }

    private enum ChapterListLoaderKey: DependencyKey {
        static let liveValue = ChapterListLoader { bookPath in
            try await ChapterListLoaderLive.load(bookPath: bookPath)
        }

        /// 测试默认值：空列表，避免忘记注入桩的测试意外读库。
        static let testValue = ChapterListLoader { _ in [] }
    }
}

/// 真实实现：从 SwiftData 读某本书的目录快照。
@MainActor
enum ChapterListLoaderLive {
    static func load(bookPath: String) throws -> [ChapterItem] {
        let container = try NovelStore.makeContainer()
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<ChapterRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        let chapters = (try? context.fetch(descriptor)) ?? []

        return chapters
            .sorted { $0.number < $1.number }
            .map {
                ChapterItem(
                    number: $0.number,
                    name: $0.name,
                    path: $0.path,
                    hasLocalText: $0.hasLocalText,
                    isDownloaded: $0.source == .downloaded
                )
            }
    }
}
