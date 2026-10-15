import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 书城 —— 分类入口 + 分类书目分页。
///
/// 分类由 `ExploreCategoryCatalog` 本地提供，不依赖首页分类导航或分类缓存。
///
/// ## 分页终止判据
/// **本页返回了未重复的新书 ⇒ 还有下一页；整页重复或空页 ⇒ 视为末页**：`hasMore` 置
/// `false` 后 `.loadMore` 一律 no-op（守卫见 `.loadMore` 分支）。
/// ⚠️ 站点列表页每页本数不定，不能按「满 30 本才继续翻」推断 —— 那正是上一版
/// 「只能看到第 1 页」的真因（每页不足 30 本 ⇒ 第 1 页后 `hasMore` 恒为 false）。
///
/// ## 「加载更多」失败是局部失败
/// 翻页失败只记在 `State.moreErrorMessage` 上，**不写 `State.errorMessage`**：
/// 后者在 `ExploreView` 的内容区里优先级最高，写它会把用户已经看到的整份书目
/// 换成整页失败态。同时 `books` / `page` / `hasMore` 一律不动，
/// `.retry` 按 `State.failedStep` 重发**同一页**，而不是退回第 1 页。
public struct ExploreFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(
            categories: [ExploreCategory] = [],
            isLoading: Bool = false,
            errorMessage: String? = nil,
            moreErrorMessage: String? = nil,
            failedStep: FailureStep? = nil,
            selectedCategory: ExploreCategory? = nil,
            books: [Book] = [],
            page: Int = 1,
            pageStarts: [ExplorePageStart] = [],
            requestID: Int = 0,
            isLoadingMore: Bool = false,
            hasMore: Bool = false
        ) {
            self.categories = categories
            self.isLoading = isLoading
            self.errorMessage = errorMessage
            self.moreErrorMessage = moreErrorMessage
            self.failedStep = failedStep
            self.selectedCategory = selectedCategory
            self.books = books
            self.page = page
            self.pageStarts = pageStarts
            self.requestID = requestID
            self.isLoadingMore = isLoadingMore
            self.hasMore = hasMore
        }

        /// 固定三维筛选目录。
        public var categories: [ExploreCategory]

        /// 选中分类的第 1 页加载中。
        public var isLoading = false

        /// 最近一次的失败 / 空结果提示。空结果与失败都不能伪装成「正常空列表」。
        ///
        /// 🔴 只表示**整页级**失败（分类列表 / 选中分类的第 1 页）：View 据此把内容区
        /// 整体换成失败态。翻页失败走 `moreErrorMessage`，不得写到这里。
        public var errorMessage: String?

        /// 「加载更多」失败原因。与 `errorMessage` **分开**：翻页失败是局部失败，
        /// 只影响底部分页行，不得把已经加载好的书目换成失败页
        /// （同 `BookDetailFeature.State.chapterErrorMessage` 的分工）。
        ///
        /// View 在底部分页行上就地显示它 + 「重试」，书目与页码原样保留。
        public var moreErrorMessage: String?

        /// 当前失败发生在哪一步：`.retry` 的**唯一**路由依据。
        ///
        /// 不从「哪个 message 非空」「分类是否为空」反推 —— 那样「加载更多失败后重试」
        /// 会被推成重拉第 1 页，把用户已经翻到的位置丢掉。
        /// 不变量：它只在失败分支与 message 同一处设置，清理统一走 `clearFailure`。
        public var failedStep: FailureStep?

        /// 当前选中的分类。未选中时书目区为空。
        public var selectedCategory: ExploreCategory?

        /// 当前分类已加载的书目。
        public var books: [Book] = []

        /// 当前分类已加载到第几页（从 1 起）。
        public var page = 1

        /// 每个已追加页面的首本书下标与服务端页号。
        public var pageStarts: [ExplorePageStart]

        /// 最新书目请求的身份；切分类或重试后旧请求不得修改当前状态。
        public var requestID: Int

        /// 正在加载当前分类的下一页。
        public var isLoadingMore = false

        /// 是否还有下一页（判定口径见类型注释）。
        public var hasMore = false
    }

    public enum Action: Equatable {
        /// 进页面：同步提供固定分类；仅首次自动加载默认组合。
        case task
        /// 选中分类：拉它的第 1 页。
        case categorySelected(ExploreCategory)
        /// 第 1 页就绪。
        case booksLoaded([Book], requestID: Int)
        /// 第 1 页失败。
        case booksFailed(String, requestID: Int)
        /// 加载当前分类的下一页。
        case loadMore
        /// 下一页就绪。
        case moreLoaded([Book], page: Int, requestID: Int)
        /// 下一页失败。**局部失败**：只记在 `State.moreErrorMessage` 上，
        /// 既有书目、页码与整页失败态都不受影响。
        case moreFailed(String, requestID: Int)
        /// 重试「当前失败的那一步」（依据 `State.failedStep`）：
        /// 首屏失败 → 重拉第 1 页；翻页失败 → 重发**同一页**。
        case retry
    }

    @Dependency(\.exploreService) var exploreService

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.categories = ExploreCategoryCatalog.allItems
                guard state.selectedCategory == nil else { return .none }
                return loadFirstPage(
                    &state,
                    category: ExploreCategoryCatalog.defaultCategory,
                    service: exploreService
                )

            case let .categorySelected(category):
                return loadFirstPage(&state, category: category, service: exploreService)

            case let .booksLoaded(books, requestID):
                guard requestID == state.requestID, state.isLoading else { return .none }
                state.books = books
                state.isLoading = false
                state.page = 1
                state.pageStarts = books.isEmpty ? [] : [ExplorePageStart(page: 1, index: 0)]
                state.hasMore = !books.isEmpty
                clearFailure(&state)
                return .none

            case let .booksFailed(message, requestID):
                guard requestID == state.requestID, state.isLoading else { return .none }
                state.isLoading = false
                state.errorMessage = message
                state.failedStep = .firstPage
                return .none

            case .loadMore:
                return loadMore(&state, service: exploreService)

            case let .moreLoaded(books, page, requestID):
                // 页码相同也可能是上个分类的旧请求，必须先核对请求身份。
                guard requestID == state.requestID, state.isLoadingMore, page == state.page + 1 else {
                    return .none
                }
                let existing = Set(state.books.map(\.path))
                let newBooks = books.filter { !existing.contains($0.path) }
                if !newBooks.isEmpty {
                    if state.pageStarts.isEmpty, !state.books.isEmpty {
                        state.pageStarts = [ExplorePageStart(page: 1, index: 0)]
                    }
                    state.pageStarts.append(ExplorePageStart(page: page, index: state.books.count))
                    state.books.append(contentsOf: newBooks)
                }
                state.page = page
                state.isLoadingMore = false
                state.hasMore = !newBooks.isEmpty
                clearFailure(&state)
                return .none

            case let .moreFailed(message, requestID):
                guard requestID == state.requestID, state.isLoadingMore else { return .none }
                // 🔴 局部失败：只写 `moreErrorMessage`，**不写 `errorMessage`**。
                // 写它会让 `ExploreView` 把整份已经加载好的书目换成整页失败态，
                // 用户翻了半天看到的书会被一次网络抖动全部顶掉。
                state.moreErrorMessage = message
                state.failedStep = .more
                state.isLoadingMore = false
                return .none

            case .retry:
                guard !state.isLoading, !state.isLoadingMore else { return .none }
                // 按**显式**记录的失败步骤重发对应请求 —— 不靠「哪个 message 非空」反推。
                guard let failedStep = state.failedStep else { return .none }
                switch failedStep {
                case .firstPage:
                    guard let category = state.selectedCategory else { return .none }
                    return loadFirstPage(&state, category: category, service: exploreService)

                case .more:
                    // 重发**同一页**：`loadMore` 只按 `page + 1` 再请求一次，
                    // 不碰 `books` / `page` / `hasMore`，所以分页位置原地保住。
                    return loadMore(&state, service: exploreService)
                }
            }
        }
    }
}

public extension ExploreFeature {
    /// 加载失败发生在哪一步（`State.failedStep`）。
    ///
    /// 首屏书目失败是整页失败（写 `errorMessage`），下一页失败是局部失败
    /// （写 `moreErrorMessage`）。`.retry` 必须重发失败的那一页。
    enum FailureStep: Equatable {
        /// 选中分类的第 1 页。
        case firstPage
        /// 当前分类的下一页。
        case more
    }
}

/// 选中分类并拉第 1 页：先把上一个分类的书目与分页游标清干净，再置 loading。
private func loadFirstPage(
    _ state: inout ExploreFeature.State,
    category: ExploreCategory,
    service: ExploreService
) -> Effect<ExploreFeature.Action> {
    state.selectedCategory = category
    state.books = []
    state.page = 1
    state.pageStarts = []
    state.hasMore = false
    state.isLoadingMore = false
    state.isLoading = true
    state.requestID += 1
    let requestID = state.requestID
    clearFailure(&state)
    return .run { send in
        do {
            let books = try await service.books(category, 1)
            await send(.booksLoaded(books, requestID: requestID))
        } catch {
            await send(.booksFailed("书目加载失败：\(error.localizedDescription)", requestID: requestID))
        }
    }
}

/// 追加当前分类的下一页。
///
/// `.loadMore` 与「加载更多失败后的重试」**共用这一条路径**：只按 `state.page + 1`
/// 再请求一次，不碰 `books` / `page` / `hasMore` —— 所以重试永远回到原来那一页，
/// 不会把用户打回第 1 页。原有守卫（末页、加载中、无选中分类）逐条保留。
private func loadMore(
    _ state: inout ExploreFeature.State,
    service: ExploreService
) -> Effect<ExploreFeature.Action> {
    // 末页或已在加载中一律不重复触发：同一页拉两次会把书目追加成重复项。
    guard state.hasMore, !state.isLoadingMore else { return .none }
    guard let category = state.selectedCategory else { return .none }
    clearFailure(&state)
    state.isLoadingMore = true
    state.requestID += 1
    let requestID = state.requestID
    let nextPage = state.page + 1
    return .run { send in
        do {
            let books = try await service.books(category, nextPage)
            await send(.moreLoaded(books, page: nextPage, requestID: requestID))
        } catch {
            await send(.moreFailed("加载更多失败：\(error.localizedDescription)", requestID: requestID))
        }
    }
}

/// 清空**全部**失败记录（两个文案 + 失败步骤）。
///
/// 语义是「已经重新发起请求 / 已经成功，旧的失败提示就不再成立」。三处字段只在失败
/// 分支同一处设置、只在这里统一清空 —— 避免出现「文案没了但步骤还留着」这种会让
/// `.retry` 走错分支的半死状态。
private func clearFailure(_ state: inout ExploreFeature.State) {
    state.errorMessage = nil
    state.moreErrorMessage = nil
    state.failedStep = nil
}

/// 书城依赖：分类列表 + 分类分页书目。
///
/// reducer 不直接调 `NovelEngine.shared`（引擎是 actor 且会真实联网），
/// 收进闭包后测试只替换闭包，就能断言完整的状态迁移。
struct ExploreService: Sendable {
    var categories: @Sendable () async throws -> [ExploreCategory]
    var books: @Sendable (ExploreCategory, Int) async throws -> [Book]
}

extension DependencyValues {
    var exploreService: ExploreService {
        get { self[ExploreServiceKey.self] }
        set { self[ExploreServiceKey.self] = newValue }
    }

    private enum ExploreServiceKey: DependencyKey {
        static let liveValue = ExploreService(
            categories: { try await NovelEngine.shared.exploreCategories() },
            books: { category, page in
                try await NovelEngine.shared.explore(category: category, page: page)
            }
        )

        /// 测试默认值：空分类 + 空书目，避免忘记注入桩时意外联网。
        static let testValue = ExploreService(
            categories: { [] },
            books: { _, _ in [] }
        )
    }
}
