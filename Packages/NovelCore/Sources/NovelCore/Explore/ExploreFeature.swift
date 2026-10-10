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
public struct ExploreFeature: Reducer {
    public init() {}

    /// 「还有下一页」的阈值：满一页才允许继续翻（与 `SearchFeature` 同口径）。
    static let pageSize = 30

    public struct State: Equatable {
        public init(
            categories: [ExploreCategory] = [],
            isLoading: Bool = false,
            errorMessage: String? = nil,
            selectedCategory: ExploreCategory? = nil,
            books: [Book] = [],
            page: Int = 1,
            isLoadingMore: Bool = false,
            hasMore: Bool = false
        ) {
            self.categories = categories
            self.isLoading = isLoading
            self.errorMessage = errorMessage
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
        public var errorMessage: String?

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
        /// 下一页失败。
        case moreFailed(String)
        /// 重试「当前失败的那一步」：还没有分类就重拉分类，否则重载当前分类的第 1 页。
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
                return loadCategories(&state, store: exploreCategoryStore, service: exploreService)

            case let .categoriesLoaded(categories):
                state.categories = categories
                state.isLoading = false
                state.errorMessage = nil
                return .none

            case let .categoriesFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case let .categorySelected(category):
                return loadFirstPage(&state, category: category, service: exploreService)

            case let .booksLoaded(books):
                state.books = books
                state.isLoading = false
                state.page = 1
                state.hasMore = books.count >= Self.pageSize
                return .none

            case let .booksFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .loadMore:
                // 末页或已在加载中一律不重复触发：同一页拉两次会把书目追加成重复项。
                guard state.hasMore, !state.isLoadingMore else { return .none }
                guard let category = state.selectedCategory else { return .none }
                state.isLoadingMore = true
                let nextPage = state.page + 1
                let service = exploreService
                return .run { send in
                    do {
                        let books = try await service.books(category, nextPage)
                        await send(.moreLoaded(books, page: nextPage))
                    } catch {
                        await send(.moreFailed("加载更多失败：\(error.localizedDescription)"))
                    }
                }

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
                return .none

            case let .moreFailed(message):
                state.isLoadingMore = false
                state.errorMessage = message
                return .none

            case .retry:
                guard !state.isLoading, !state.isLoadingMore else { return .none }
                guard !state.categories.isEmpty else {
                    return loadCategories(&state, store: exploreCategoryStore, service: exploreService)
                }
                guard let category = state.selectedCategory else { return .none }
                return loadFirstPage(&state, category: category, service: exploreService)
            }
        }
    }
}

/// 读缓存 → 命中即用；未命中才联网并落盘。
///
/// `.task` 与 `.retry` 走同一条路径，所以顺手把首屏 loading / 错误态复位也收在这里。
private func loadCategories(
    _ state: inout ExploreFeature.State,
    store: ExploreCategoryStore,
    service: ExploreService
) -> Effect<ExploreFeature.Action> {
    state.isLoading = true
    state.errorMessage = nil
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
    state.errorMessage = nil
    return .run { send in
        do {
            let books = try await service.books(category, 1)
            await send(.booksLoaded(books))
        } catch {
            await send(.booksFailed("书目加载失败：\(error.localizedDescription)"))
        }
    }
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
