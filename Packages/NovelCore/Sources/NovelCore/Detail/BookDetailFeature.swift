import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 书籍详情快照。字段全部来自搜索/详情页解析，缺失时留空，由 UI 显示“暂无”。
public struct BookDetail: Equatable, Identifiable, Sendable {
    public init(book: Book) {
        bookPath = book.path
        title = book.title
        author = book.author
        coverUrl = book.coverUrl
        intro = book.intro
        status = book.status
        category = book.category
        tags = book.tags
        wordCount = book.wordCount
        lastChapter = book.lastChapter
        lastUpdated = book.lastUpdated
    }

    public init(
        bookPath: String,
        title: String,
        author: String = "",
        coverUrl: String = "",
        intro: String = "",
        status: String = "",
        category: String = "",
        tags: [String] = [],
        wordCount: String = "",
        lastChapter: String = "",
        lastUpdated: String = ""
    ) {
        self.bookPath = bookPath
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.status = status
        self.category = category
        self.tags = tags
        self.wordCount = wordCount
        self.lastChapter = lastChapter
        self.lastUpdated = lastUpdated
    }

    public var id: String {
        bookPath
    }

    public var bookPath: String
    public var title: String
    public var author: String
    public var coverUrl: String
    public var intro: String
    public var status: String
    public var category: String
    public var tags: [String]
    public var wordCount: String
    public var lastChapter: String
    public var lastUpdated: String
}

/// 详情页状态。
public struct BookDetailFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(fallback: BookDetail) {
            self.fallback = fallback
            detail = fallback
        }

        public var fallback: BookDetail
        public var detail: BookDetail
        public var isLoading = false
        public var errorMessage: String?
    }

    public enum Action: Equatable {
        case onAppear
        case loaded(BookDetail)
        case loadFailed(String)
    }

    @Dependency(\.bookDetailLoader) var loader

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let fallback = state.fallback
                let loader = loader
                return .run { send in
                    do {
                        let loaded = try await loader.load(fallback.bookPath)
                        await send(.loaded(loaded ?? fallback))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .loaded(detail):
                state.detail = detail
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none
            }
        }
    }
}

struct BookDetailLoader: Sendable {
    var load: @Sendable (String) async throws -> BookDetail?
}

extension DependencyValues {
    var bookDetailLoader: BookDetailLoader {
        get { self[BookDetailLoaderKey.self] }
        set { self[BookDetailLoaderKey.self] = newValue }
    }

    private enum BookDetailLoaderKey: DependencyKey {
        static let liveValue = BookDetailLoader { bookPath in
            try await BookDetailLoaderLive.load(bookPath: bookPath)
        }

        static let testValue = BookDetailLoader { _ in nil }
    }
}

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
            lastUpdated: record.lastUpdated
        )
    }
}
