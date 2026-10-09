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

public extension BookDetail {
    /// 详情 → 引擎书模型。
    ///
    /// 「加入书架」复用 `ShelfAdder.add(_:)` 这条**既有**落库路径（与搜索结果页同一条），
    /// 所以详情页需要把快照还原成 `Book`，而不是新造一条「按 bookPath 加书」的依赖。
    /// 字段与 `Book` 一一对应，其中详情页独有的 `intro` 等也只做搬运，不做加工。
    var book: Book {
        var model = Book(path: bookPath, title: title)
        model.author = author
        model.intro = intro
        model.lastChapter = lastChapter
        model.wordCount = wordCount
        model.coverUrl = coverUrl
        model.status = status
        model.category = category
        model.tags = tags
        model.lastUpdated = lastUpdated
        return model
    }
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

        /// 这本书当前是否已在书架。界面据此在「加入书架 / 移出书架」之间切换。
        ///
        /// 🔴 只在 `onAppear` 读一次本地记录（命中 `BookRecord` == 已在书架），
        /// 不在渲染路径上查库；加入 / 移出成功后由对应 action 直接改这个值。
        public var isOnShelf = false

        /// 加入 / 移出进行中。同一页一次只可能有一个书架操作，用布尔即可。
        public var isShelfBusy = false

        /// 加入 / 移出失败提示（就地显示在按钮下方，不阻断页面）。
        public var shelfNotice: String?

        /// 最近一次成功加入的书架行，供上层（搜索页）即时同步列表。
        /// 与 `SearchFeature.lastAddedRow` 同一套路：本层不知道谁在用，只把结果抛出去。
        public var lastAddedRow: ShelfRow?

        /// 最近一次移出书架的书路径，供上层（书架页 / 搜索页）把这本书从列表里摘掉。
        public var lastRemovedPath: String?
    }

    public enum Action: Equatable {
        case onAppear
        /// 详情加载完成。`nil` 表示本地没有这本书的记录 —— 也就是**不在书架**。
        case loaded(BookDetail?)
        case loadFailed(String)

        /// 点「加入书架」。
        case addRequested
        case addSucceeded(ShelfRow)
        /// 加入失败。`alreadyExists` 为 `true` 表示失败原因是「这本书已在书架里」——
        /// 界面要据此切到「移出书架」，而不是留在「加入书架」让用户反复点到失败。
        case addFailed(message: String, alreadyExists: Bool)

        /// 点「移出书架」。
        case removeRequested
        case removeSucceeded
        case removeFailed(String)
    }

    @Dependency(\.bookDetailLoader) var loader
    @Dependency(\.shelfAdder) var shelfAdder
    @Dependency(\.shelfGroupStore) var shelfGroupStore

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
                        await send(.loaded(loaded))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .loaded(loaded):
                // 🔴 `nil` 就是「不在书架」：`BookDetailLoaderLive` 只在命中 `BookRecord`
                // （加入书架时才写入）时返回非 nil，读不到记录必然意味着没加过。
                state.isOnShelf = loaded != nil
                state.detail = loaded ?? state.fallback
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .addRequested:
                // 已在书架 / 正在处理时不重复发请求（此时按钮本应是「移出书架」）。
                guard !state.isShelfBusy, !state.isOnShelf else { return .none }
                state.isShelfBusy = true
                state.shelfNotice = nil
                let book = state.detail.book
                let adder = shelfAdder
                return .run { send in
                    do {
                        let row = try await adder.add(book)
                        await send(.addSucceeded(row))
                    } catch let error as ShelfAdderError {
                        // 显式 switch 而非 `if case`：`ShelfAdderError` 将来加 case 时这里会编译报错。
                        switch error {
                        case .alreadyExists:
                            await send(.addFailed(
                                message: error.localizedDescription,
                                alreadyExists: true
                            ))
                        }
                    } catch {
                        await send(.addFailed(
                            message: error.localizedDescription,
                            alreadyExists: false
                        ))
                    }
                }

            case let .addSucceeded(row):
                state.isShelfBusy = false
                state.isOnShelf = true
                state.lastAddedRow = row
                return .none

            case let .addFailed(message, alreadyExists):
                state.isShelfBusy = false
                state.shelfNotice = message
                // 已经在书架里 == 状态其实是「已加入」，顺手把按钮切对。
                if alreadyExists {
                    state.isOnShelf = true
                }
                return .none

            case .removeRequested:
                guard !state.isShelfBusy, state.isOnShelf else { return .none }
                state.isShelfBusy = true
                state.shelfNotice = nil
                let bookPath = state.detail.bookPath
                let store = shelfGroupStore
                return .run { send in
                    do {
                        // 复用书架批量删书那条既有路径（清元数据 + 清正文文件 + 清下载任务），
                        // 这里一次只传一本 —— 不新造「单本移除」，避免两套清理逻辑分叉。
                        try await store.removeBooks([bookPath])
                        await send(.removeSucceeded)
                    } catch {
                        await send(.removeFailed(error.localizedDescription))
                    }
                }

            case .removeSucceeded:
                state.isShelfBusy = false
                state.isOnShelf = false
                state.lastRemovedPath = state.detail.bookPath
                return .none

            case let .removeFailed(message):
                state.isShelfBusy = false
                state.shelfNotice = message
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
