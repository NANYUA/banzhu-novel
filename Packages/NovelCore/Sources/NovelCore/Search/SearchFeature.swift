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
            pageStarts: [SearchPageStart] = [],
            isLoadingMore: Bool = false,
            loadMoreFailed: Bool = false,
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
            self.pageStarts = pageStarts
            self.isLoadingMore = isLoadingMore
            self.loadMoreFailed = loadMoreFailed
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

        /// 每一页的第一本书：**页码 + 它在 `results` 里的起始下标**（第 1 页恒为 `(1, 0)`）。
        ///
        /// 🔴 下标必须单独记：`.moreSucceeded` 是**按书路径去重后追加**的，
        /// 一旦有重复被滤掉，页边界就无法从 `results` 反推。
        /// 🔴 页码必须跟下标**记在一起**、不能靠数组下标 +1 推算：整页都是重复时这一页
        /// 不记（见 `.moreSucceeded`），若用数组下标推算，它后面所有页的页码都会整体少 1 ——
        /// 而「提醒我下面的书是第几页的内容」正是这些标签的全部意义。
        public var pageStarts: [SearchPageStart] = []

        /// 正在加载下一页。
        public var isLoadingMore = false

        /// 上一次 `.loadMore` 失败了 —— 加载行据此变成**可点的「加载失败，点一下重试」**。
        ///
        /// 为什么单独一个字段、而不是复用 `notice`：`notice` 是 1 秒后自动消失的顶部提示条，
        /// 它消失之后用户就没有任何「还能重试」的入口了；失败态必须**留在列表底部**直到重试成功。
        /// 复位点见 `.search` / `.searchSucceeded` / `.loadMore` / `.moreSucceeded`。
        public var loadMoreFailed = false

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
        /// 加入失败。`alreadyExists` 为 `true` 表示失败原因是「这本书已在书架里」——
        /// 界面要据此把该行切到「已加入」，而不是留在「加入书架」让用户反复点。
        case addFailed(bookPath: String, message: String, alreadyExists: Bool)
        /// 详情页把这本书移出书架，搜索结果要同步取消「已加入」状态。
        case removedFromShelf(bookPath: String)
        /// 关闭提示。
        case noticeDismissed
        /// 跳到指定页码：用第 N 页的结果替换当前结果。
        case jumpToPage(Int)
        /// 跳页就绪。
        case jumpedToPage([Book], page: Int)
        /// 跳页失败。
        case jumpFailed(String)
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
                state.pageStarts = []
                state.loadMoreFailed = false
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
                // 第 1 页的书从 `results` 的第 0 位开始；视图侧据此**不**在列表开头插标签。
                state.pageStarts = [SearchPageStart(page: 1, index: 0)]
                state.loadMoreFailed = false
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
                state.loadMoreFailed = false
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
                let newBooks = books.filter { !existing.contains($0.path) }
                // 先记起始下标再追加：重复被滤掉时，这一页的「第一本书」就是
                // `newBooks.first`，而它落在 `results` 里的下标正是追加前的 `results.count`。
                // 页码用服务端给的 `page`，**不是** `pageStarts.count + 1`：
                // 整页都是重复（`newBooks` 为空）时这一页不记（记了会画出一行没有书跟其后的标签），
                // 但后面真实落地的那一页仍要显示自己的真实页号。
                if !newBooks.isEmpty {
                    state.pageStarts.append(SearchPageStart(page: page, index: state.results.count))
                }
                state.results.append(contentsOf: newBooks)
                state.page = page
                state.isLoadingMore = false
                state.loadMoreFailed = false
                state.hasMore = books.count >= 30
                return .none

            case let .moreFailed(message):
                state.isLoadingMore = false
                // 失败态留在列表底部（加载行变成可点的重试按钮），直到下一次重试成功。
                state.loadMoreFailed = true
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
                    } catch let error as ShelfAdderError {
                        // 🔴 单独识别「已在书架」：用户点「加入书架」时这本书可能早就加过了
                        // （上一次启动加的），提示之外还得把按钮切成「已加入」。
                        // 显式 switch 而非 `if case`：`ShelfAdderError` 将来加 case 时这里会编译报错。
                        switch error {
                        case .alreadyExists:
                            await send(.addFailed(
                                bookPath: book.path,
                                message: error.localizedDescription,
                                alreadyExists: true
                            ))
                        }
                    } catch {
                        await send(.addFailed(
                            bookPath: book.path,
                            message: error.localizedDescription,
                            alreadyExists: false
                        ))
                    }
                }

            case let .addSucceeded(row):
                state.addingPaths.remove(row.bookPath)
                state.addedPaths.insert(row.bookPath)
                state.notice = "《\(row.title)》已加入书架。"
                state.lastAddedRow = row
                return .none

            case let .addFailed(bookPath, message, alreadyExists):
                state.addingPaths.remove(bookPath)
                // 已经在书架里 == 状态其实是「已加入」，顺手把该行切对。
                if alreadyExists {
                    state.addedPaths.insert(bookPath)
                }
                state.notice = message
                return .none

            case let .removedFromShelf(bookPath):
                // 详情页移出书架后，搜索结果不能继续显示「已加入」并挡住「加入书架」。
                state.addedPaths.remove(bookPath)
                return .none

            case .noticeDismissed:
                state.notice = nil
                return .none

            case let .jumpToPage(page):
                guard page >= 1 else { return .none }
                let keyword = state.submittedKeyword
                guard !keyword.isEmpty else { return .none }
                state.results = []
                state.isLoading = true
                state.errorMessage = nil
                state.notice = nil
                state.page = page
                state.pageStarts = []
                state.loadMoreFailed = false
                state.hasMore = false
                let service = searchService
                return .run { send in
                    do {
                        let books = try await service.search(keyword, page)
                        await send(.jumpedToPage(books, page: page))
                    } catch {
                        await send(.jumpFailed(error.localizedDescription))
                    }
                }

            case let .jumpedToPage(books, page):
                state.results = books
                state.isLoading = false
                state.page = page
                // 第 N 页的书从 `results` 的第 0 位开始，后续 `.moreSucceeded` 继续往后追加。
                state.pageStarts = [SearchPageStart(page: page, index: 0)]
                state.loadMoreFailed = false
                state.hasMore = books.count >= 30
                return .none

            case let .jumpFailed(message):
                state.results = []
                state.isLoading = false
                state.errorMessage = message
                return .none
            }
        }
    }
}

/// 「某一页的第一本书」：页号 + 这本书在 `SearchFeature.State.results` 里的起始下标。
///
/// 页号必须**跟下标一起记**（而不是在视图层用数组下标 +1 推算）：整页都是重复时那一页
/// 不记录（否则会画出一行后面没有书的页码标签），靠下标推算会让它后面所有页的页码整体少 1。
public struct SearchPageStart: Equatable {
    /// 服务端页号（从 1 开始）。
    public let page: Int
    /// 该页第一本书在 `results` 里的下标。
    public let index: Int

    public init(page: Int, index: Int) {
        self.page = page
        self.index = index
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
