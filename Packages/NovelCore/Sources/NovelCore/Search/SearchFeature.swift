import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 搜索页 —— 输入关键词、加载结果、把书加入书架。
///
/// ## 为什么搜索能力单独收成依赖
/// `NovelEngine.search` 是 actor 且会真实联网；reducer 直接调用它会让测试
/// 必须 mock 网络。收进 `SearchService` 后，测试只替换一个闭包即可断言完整状态迁移。
///
/// ## 搜索与加书架的关系
/// 搜索只负责「找到书」。加入书架复用 `ShelfAdder`，与书架页的加入操作同一条落库路径，
/// 避免搜索结果和书架结果因为两套逻辑产生分叉。
public struct SearchFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(
            keyword: String = "",
            submittedKeyword: String = "",
            results: [Book] = [],
            isLoading: Bool = false,
            errorMessage: String? = nil,
            addingPaths: Set<String> = [],
            addedPaths: Set<String> = [],
            page: Int = 1,
            isLoadingMore: Bool = false,
            hasMore: Bool = false,
            notice: String? = nil,
            lastAddedRow: ShelfRow? = nil
        ) {
            self.keyword = keyword
            self.submittedKeyword = submittedKeyword
            self.results = results
            self.isLoading = isLoading
            self.errorMessage = errorMessage
            self.addingPaths = addingPaths
            self.addedPaths = addedPaths
            self.page = page
            self.isLoadingMore = isLoadingMore
            self.hasMore = hasMore
            self.notice = notice
            self.lastAddedRow = lastAddedRow
        }

        /// 用户当前输入的关键词。提交前不会触发网络请求。
        public var keyword = ""

        /// 最近一次真正提交搜索的关键词。用于空态文案。
        public var submittedKeyword = ""

        /// 搜索结果。
        public var results: [Book] = []

        /// 搜索请求中。
        public var isLoading = false

        /// 搜索失败原因。空结果与失败必须分开呈现。
        public var errorMessage: String?

        /// 正在加入书架的书路径集合。按书路径去重，重复点击不会并发发两次。
        public var addingPaths: Set<String> = []

        /// 已加入书架的书路径；用于隐藏加入按钮并阻止重复加入。
        public var addedPaths: Set<String> = []

        /// 已加载到第几页。
        public var page = 1

        /// 正在加载下一页。
        public var isLoadingMore = false

        /// 是否还有下一页。页面返回满 30 本时继续允许加载。
        public var hasMore = false

        /// 加入书架结果提示（成功/重复/失败），不阻断搜索列表。
        public var notice: String?

        /// 最近一次成功加入书架的行，供根视图即时同步书架列表。
        public var lastAddedRow: ShelfRow?
    }

    public enum Action: Equatable {
        /// 输入框内容变化。
        case keywordChanged(String)
        /// 提交搜索。
        case search
        /// 搜索成功。
        case searchSucceeded([Book])
        /// 搜索失败。
        case searchFailed(String)
        /// 加载下一页。
        case loadMore
        /// 下一页成功。
        case moreSucceeded([Book], page: Int)
        /// 下一页失败。
        case moreFailed(String)
        /// 点击搜索结果里的「加入书架」。
        case addRequested(Book)
        /// 加入成功。
        case addSucceeded(ShelfRow)
        /// 加入失败。
        case addFailed(bookPath: String, message: String)
        /// 关闭提示。
        case noticeDismissed
    }

    @Dependency(\.searchService) var searchService
    @Dependency(\.shelfAdder) var shelfAdder

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .keywordChanged(keyword):
                state.keyword = keyword
                return .none

            case .search:
                let keyword = state.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyword.isEmpty else {
                    state.errorMessage = "请输入书名或作者名。"
                    return .none
                }
                state.submittedKeyword = keyword
                state.isLoading = true
                state.errorMessage = nil
                state.notice = nil
                state.page = 1
                state.hasMore = false
                let service = searchService
                return .run { send in
                    do {
                        let books = try await service.search(keyword, 1)
                        await send(.searchSucceeded(books))
                    } catch {
                        await send(.searchFailed(error.localizedDescription))
                    }
                }

            case let .searchSucceeded(books):
                state.results = books
                state.isLoading = false
                state.page = 1
                state.hasMore = books.count >= 30
                return .none

            case let .searchFailed(message):
                state.results = []
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .loadMore:
                guard state.hasMore, !state.isLoading, !state.isLoadingMore else {
                    return .none
                }
                let keyword = state.submittedKeyword
                guard !keyword.isEmpty else { return .none }
                state.isLoadingMore = true
                state.notice = nil
                let nextPage = state.page + 1
                let service = searchService
                return .run { send in
                    do {
                        let books = try await service.search(keyword, nextPage)
                        await send(.moreSucceeded(books, page: nextPage))
                    } catch {
                        await send(.moreFailed(error.localizedDescription))
                    }
                }

            case let .moreSucceeded(books, page):
                let existing = Set(state.results.map(\.path))
                state.results.append(contentsOf: books.filter { !existing.contains($0.path) })
                state.page = page
                state.isLoadingMore = false
                state.hasMore = books.count >= 30
                return .none

            case let .moreFailed(message):
                state.isLoadingMore = false
                state.notice = message
                return .none

            case let .addRequested(book):
                guard !state.addingPaths.contains(book.path) else { return .none }
                guard !state.addedPaths.contains(book.path) else { return .none }
                state.addingPaths.insert(book.path)
                state.notice = nil
                let adder = shelfAdder
                return .run { send in
                    do {
                        let row = try await adder.add(book)
                        await send(.addSucceeded(row))
                    } catch {
                        await send(.addFailed(bookPath: book.path, message: error.localizedDescription))
                    }
                }

            case let .addSucceeded(row):
                state.addingPaths.remove(row.bookPath)
                state.addedPaths.insert(row.bookPath)
                state.notice = "《\(row.title)》已加入书架。"
                state.lastAddedRow = row
                return .none

            case let .addFailed(bookPath, message):
                state.addingPaths.remove(bookPath)
                state.notice = message
                return .none

            case .noticeDismissed:
                state.notice = nil
                return .none
            }
        }
    }
}

/// 搜索依赖。
struct SearchService: Sendable {
    var search: @Sendable (String, Int) async throws -> [Book]
}

extension DependencyValues {
    var searchService: SearchService {
        get { self[SearchServiceKey.self] }
        set { self[SearchServiceKey.self] = newValue }
    }

    private enum SearchServiceKey: DependencyKey {
        static let liveValue = SearchService { keyword, page in
            try await NovelEngine.shared.search(keyword: keyword, page: page)
        }

        /// 测试默认值：空结果，避免忘记注入桩时意外联网。
        static let testValue = SearchService { _, _ in [] }
    }
}
