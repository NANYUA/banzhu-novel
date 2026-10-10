import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 书城 —— 分类入口 + 分类书目分页。
///
/// ## 为什么分类要落盘缓存（「固定分类」）
/// 分类由引擎的 `exploreCategories()` 从首页抽一次得到，**抓一次就稳定存在**。
/// 每次进页面都联网的话，网络一抖用户看到的就是一个空书城。
/// 所以 `.task` 先读落盘缓存，**只有缓存缺失才联网**，拿到后立刻写回
/// （见 `loadCategories`；读写实现见 `ExploreCategoryStore.swift`）。
///
/// ## 分页终止判据
/// **返回不足一页（`pageSize` = 30 本）即视为末页**：`hasMore` 置 `false`，
/// 之后 `.loadMore` 一律 no-op（守卫见 `.loadMore` 分支）。
/// 阈值与 `SearchFeature` 的分页口径一致（书目列表页满一页才继续翻）。
/// ⚠️ 若列表页实际每页不足 30 本，翻页会提前停住 —— 只需改 `pageSize` 一处。
///
/// ## 「加载更多」失败是局部失败
/// 翻页失败只记在 `State.moreErrorMessage` 上，**不写 `State.errorMessage`**：
/// 后者在 `ExploreView` 的内容区里优先级最高，写它会把用户已经看到的整份书目
/// 换成整页失败态。同时 `books` / `page` / `hasMore` 一律不动，
/// `.retry` 按 `State.failedStep` 重发**同一页**，而不是退回第 1 页。
public struct ExploreFeature: Reducer {
    public init() {}

    /// 「还有下一页」的阈值：满一页才允许继续翻（与 `SearchFeature` 同口径）。
    static let pageSize = 30

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
            self.isLoadingMore = isLoadingMore
            self.hasMore = hasMore
        }

        /// 书城分类（来自落盘缓存或一次联网）。
        public var categories: [ExploreCategory]

        /// 首屏加载中：分类列表本身，或选中分类的第 1 页。
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

        /// 正在加载当前分类的下一页。
        public var isLoadingMore = false

        /// 是否还有下一页（判定口径见类型注释）。
        public var hasMore = false
    }

    public enum Action: Equatable {
        /// 进页面：先读缓存，缺失才联网并落盘。
        case task
        /// 分类就绪（缓存命中或联网成功）。
        case categoriesLoaded([ExploreCategory])
        /// 分类没拿到：联网失败，或首页解析不出分类。`String` 是已组装好的中文文案。
        case categoriesFailed(String)
        /// 选中分类：拉它的第 1 页。
        case categorySelected(ExploreCategory)
        /// 第 1 页就绪。
        case booksLoaded([Book])
        /// 第 1 页失败。
        case booksFailed(String)
        /// 加载当前分类的下一页。
        case loadMore
        /// 下一页就绪。
        case moreLoaded([Book], page: Int)
        /// 下一页失败。**局部失败**：只记在 `State.moreErrorMessage` 上，
        /// 既有书目、页码与整页失败态都不受影响。
        case moreFailed(String)
        /// 重试「当前失败的那一步」（依据 `State.failedStep`）：
        /// 分类失败 → 重拉分类；首屏失败 → 重拉第 1 页；翻页失败 → 重发**同一页**。
        case retry
    }

    @Dependency(\.exploreService) var exploreService
    @Dependency(\.exploreCategoryStore) var exploreCategoryStore

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // 页面每次出现都会发 `.task`：已在加载中就不重复发，避免打两次首页。
                guard !state.isLoading else { return .none }
                // 手上已经有分类（切回 tab / 从详情页 pop 回来）⇒ **静默刷新**：不进首屏加载态，
                // 否则已经展示出来的分类胶囊与书目会被 spinner 顶掉再回来。
                let showsLoading = state.categories.isEmpty
                return loadCategories(
                    &state,
                    store: exploreCategoryStore,
                    service: exploreService,
                    showsLoading: showsLoading
                )

            case let .categoriesLoaded(categories):
                state.categories = categories
                state.isLoading = false
                clearFailure(&state)
                return .none

            case let .categoriesFailed(message):
                state.isLoading = false
                state.errorMessage = message
                state.failedStep = .categories
                return .none

            case let .categorySelected(category):
                return loadFirstPage(&state, category: category, service: exploreService)

            case let .booksLoaded(books):
                state.books = books
                state.isLoading = false
                state.page = 1
                state.hasMore = books.count >= Self.pageSize
                clearFailure(&state)
                return .none

            case let .booksFailed(message):
                state.isLoading = false
                state.errorMessage = message
                state.failedStep = .firstPage
                return .none

            case .loadMore:
                return loadMore(&state, service: exploreService)

            case let .moreLoaded(books, page):
                // 切换分类后旧请求可能晚到：页码对不上就丢弃，
                // 否则会把上一个分类的书追加进当前列表。
                guard page == state.page + 1 else {
                    state.isLoadingMore = false
                    return .none
                }
                let existing = Set(state.books.map(\.path))
                state.books.append(contentsOf: books.filter { !existing.contains($0.path) })
                state.page = page
                state.isLoadingMore = false
                state.hasMore = books.count >= Self.pageSize
                clearFailure(&state)
                return .none

            case let .moreFailed(message):
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
                case .categories:
                    // 显式重试一律给 loading 反馈（静默刷新只属于 `.task`）。
                    return loadCategories(
                        &state,
                        store: exploreCategoryStore,
                        service: exploreService,
                        showsLoading: true
                    )

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
    /// 三个阶段各有独立的失败态：分类没拿到与首屏书目失败都是**整页失败**
    /// （写 `errorMessage`），下一页失败是**局部失败**（写 `moreErrorMessage`）。
    /// `.retry` 必须知道是哪一步，才能重发对应的那一条请求 —— 尤其不能在
    /// 「翻页失败」时重拉第 1 页，那等于把用户已经翻开的分页位置丢掉。
    enum FailureStep: Equatable {
        /// 分类列表（`.task` 缓存缺失后的那一次联网）。
        case categories
        /// 选中分类的第 1 页。
        case firstPage
        /// 当前分类的下一页。
        case more
    }
}

/// 读缓存 → 命中即用；未命中才联网并落盘。
///
/// `.task` 与 `.retry` 走同一条路径，差别只在 `showsLoading`：`.task` 传
/// `state.categories.isEmpty`（手上已经有分类就**静默刷新**，别用 spinner 把已经展示出来的
/// 内容顶掉），`.retry` 传 `true`（显式重试必须看得到 loading 反馈）。
/// 首屏 loading / 失败态复位也收在这里。
private func loadCategories(
    _ state: inout ExploreFeature.State,
    store: ExploreCategoryStore,
    service: ExploreService,
    showsLoading: Bool
) -> Effect<ExploreFeature.Action> {
    state.isLoading = showsLoading
    clearFailure(&state)
    return .run { send in
        if let cached = await store.load(), !cached.isEmpty {
            await send(.categoriesLoaded(cached))
            return
        }
        do {
            let categories = try await service.categories()
            // 引擎对「首页解析不出分类」不抛错而是返回空数组（见 `exploreCategories` 文档）：
            // 必须与「成功」分开呈现，并且**不落盘** —— 别用一次空结果覆盖掉已有缓存。
            guard !categories.isEmpty else {
                await send(.categoriesFailed("未解析到书城分类，请稍后重试。"))
                return
            }
            await store.save(categories)
            await send(.categoriesLoaded(categories))
        } catch {
            await send(.categoriesFailed("分类加载失败：\(error.localizedDescription)"))
        }
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
    state.hasMore = false
    state.isLoadingMore = false
    state.isLoading = true
    clearFailure(&state)
    return .run { send in
        do {
            let books = try await service.books(category, 1)
            await send(.booksLoaded(books))
        } catch {
            await send(.booksFailed("书目加载失败：\(error.localizedDescription)"))
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
    let nextPage = state.page + 1
    return .run { send in
        do {
            let books = try await service.books(category, nextPage)
            await send(.moreLoaded(books, page: nextPage))
        } catch {
            await send(.moreFailed("加载更多失败：\(error.localizedDescription)"))
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
