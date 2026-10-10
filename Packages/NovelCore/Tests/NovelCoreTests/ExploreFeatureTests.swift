import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 书城测试的共享夹具：全部是**中性合成形状**，不含任何真实站点信息。
private enum ExploreTestData {
    /// `{{page}}` 是引擎要求的页码占位符。
    static let category = ExploreCategory(
        title: "示例分类",
        urlTemplate: "/catalog/1_{{page}}.html"
    )

    /// 满一页（`pageSize` 本）——用来构造「还有下一页」的初态。
    static func fullPage(_ prefix: Int) -> [Book] {
        (0 ..< ExploreFeature.pageSize).map {
            Book(path: "/book/\(prefix)_\($0)/", title: "示例书 \(prefix)-\($0)")
        }
    }
}

@MainActor
final class ExploreFeatureTests: XCTestCase {
    // MARK: - ① 有缓存：直接用缓存，不发网络请求

    func test有缓存时直接用缓存不发网络请求() async {
        let cached = [ExploreTestData.category]
        let recorder = ExploreCallRecorder()
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreCategoryStore.load = { cached }
            $0.exploreCategoryStore.save = { categories in
                await recorder.recordSave(categories)
            }
            $0.exploreService.categories = {
                await recorder.recordCategories()
                return cached
            }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.categoriesLoaded(cached)) {
            $0.categories = cached
            $0.isLoading = false
        }
        await store.finish()

        let categoriesCalls = await recorder.categoryCallCount()
        let saveBatches = await recorder.saveBatches()
        XCTAssertEqual(categoriesCalls, 0, "缓存命中时不应再联网拉分类")
        XCTAssertTrue(saveBatches.isEmpty, "缓存命中时不应重复落盘")
    }

    // MARK: - ② 无缓存：拉一次网并落盘

    func test无缓存时拉一次网并落盘() async {
        let fetched = [ExploreTestData.category]
        let recorder = ExploreCallRecorder()
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreCategoryStore.load = { nil }
            $0.exploreCategoryStore.save = { categories in
                await recorder.recordSave(categories)
            }
            $0.exploreService.categories = {
                await recorder.recordCategories()
                return fetched
            }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.categoriesLoaded(fetched)) {
            $0.categories = fetched
            $0.isLoading = false
        }
        await store.finish()

        let categoriesCalls = await recorder.categoryCallCount()
        let saveBatches = await recorder.saveBatches()
        XCTAssertEqual(categoriesCalls, 1, "无缓存时应恰好联网一次")
        XCTAssertEqual(saveBatches.count, 1, "拉到的分类应恰好落盘一次")
        XCTAssertEqual(saveBatches.first?.map(\.title), ["示例分类"])
        XCTAssertEqual(saveBatches.first?.first?.urlTemplate, "/catalog/1_{{page}}.html")
    }

    func test首页解析不出分类时不落盘并提示() async {
        let recorder = ExploreCallRecorder()
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreCategoryStore.load = { nil }
            $0.exploreCategoryStore.save = { categories in
                await recorder.recordSave(categories)
            }
            // 引擎对「解析不出分类」不抛错，而是返回空数组。
            $0.exploreService.categories = { [] }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.categoriesFailed("未解析到书城分类，请稍后重试。")) {
            $0.isLoading = false
            $0.errorMessage = "未解析到书城分类，请稍后重试。"
        }
        await store.finish()

        let saveBatches = await recorder.saveBatches()
        XCTAssertTrue(saveBatches.isEmpty, "一次空结果不得覆盖已有缓存")
        XCTAssertFalse(store.state.isLoading, "空结果也必须复位 loading")
    }

    // MARK: - ③ 选中分类：拉第 1 页并填入书目

    func test选中分类拉第1页并填入书目() async {
        let book = Book(path: "/book/1_1/", title: "示例书")
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(categories: [ExploreTestData.category])
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                await recorder.recordBooks(title: category.title, page: page)
                return [book]
            }
        }

        await store.send(.categorySelected(ExploreTestData.category)) {
            $0.selectedCategory = ExploreTestData.category
            $0.isLoading = true
        }
        await store.receive(.booksLoaded([book])) {
            $0.books = [book]
            $0.isLoading = false
        }
        await store.finish()

        let calls = await recorder.bookCalls()
        XCTAssertEqual(calls.first?.title, "示例分类")
        XCTAssertEqual(calls.first?.page, 1, "选中分类应拉第 1 页")
    }

    // MARK: - ⑤ 失败路径：写 errorMessage 且复位 loading

    func test书目加载失败写入错误文案并复位加载态() async {
        struct BooksUnavailable: LocalizedError {
            var errorDescription: String? {
                "网络不可用。"
            }
        }

        let store = TestStore(
            initialState: ExploreFeature.State(categories: [ExploreTestData.category])
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { _, _ in throw BooksUnavailable() }
        }

        await store.send(.categorySelected(ExploreTestData.category)) {
            $0.selectedCategory = ExploreTestData.category
            $0.isLoading = true
        }
        await store.receive(.booksFailed("书目加载失败：网络不可用。")) {
            $0.isLoading = false
            $0.errorMessage = "书目加载失败：网络不可用。"
        }
        await store.finish()

        XCTAssertFalse(store.state.isLoading, "失败后必须复位 loading")
    }

    func test分类失败后重试可重新拉取() async {
        let fetched = [ExploreTestData.category]
        let store = TestStore(
            initialState: ExploreFeature.State(errorMessage: "分类加载失败：连接超时。")
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreCategoryStore.load = { nil }
            $0.exploreService.categories = { fetched }
        }

        await store.send(.retry) {
            $0.isLoading = true
            $0.errorMessage = nil
        }
        await store.receive(.categoriesLoaded(fetched)) {
            $0.categories = fetched
            $0.isLoading = false
        }
        await store.finish()
    }

    // MARK: - 落盘快照：能存能读

    func test分类快照JSON往返保留标题与路径模板() throws {
        let original = [ExploreTestData.category]
        let data = try JSONEncoder().encode(original.map { ExploreCategorySnapshot($0) })
        let decoded = try JSONDecoder().decode([ExploreCategorySnapshot].self, from: data)

        XCTAssertEqual(decoded.map(\.category), original)
        XCTAssertEqual(decoded.first?.title, "示例分类")
        XCTAssertEqual(decoded.first?.urlTemplate, "/catalog/1_{{page}}.html")
    }
}

/// 分页：追加、加载中 no-op、末页判据。
@MainActor
final class ExplorePagingTests: XCTestCase {
    // MARK: - ④ 加载下一页：追加；已在加载中则 no-op

    func test加载下一页追加书目() async {
        let pageOne = ExploreTestData.fullPage(1)
        let pageTwo = [Book(path: "/book/2_1/", title: "示例书 2-1")]
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [ExploreTestData.category],
                selectedCategory: ExploreTestData.category,
                books: pageOne,
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                await recorder.recordBooks(title: category.title, page: page)
                return pageTwo
            }
        }

        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreLoaded(pageTwo, page: 2)) {
            $0.books = pageOne + pageTwo
            $0.page = 2
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        await store.finish()

        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [2], "下一页应请求第 2 页")
    }

    func test加载中重复触发加载下一页是空操作() async {
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [ExploreTestData.category],
                selectedCategory: ExploreTestData.category,
                books: ExploreTestData.fullPage(1),
                isLoadingMore: true,
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                await recorder.recordBooks(title: category.title, page: page)
                return []
            }
        }

        // ⚠️ 这一次不改变任何状态（no-op）⇒ 不能传尾随闭包，
        // 否则 TestStore 会报 `Expected state to change, but no change occurred.`
        await store.send(.loadMore)
        await store.finish()

        let calls = await recorder.bookCalls()
        XCTAssertTrue(calls.isEmpty, "已在加载下一页时不得重复发请求")
    }

    func test返回不足一页视为末页且不再翻页() async {
        let pageOne = ExploreTestData.fullPage(1)
        let lastBook = Book(path: "/book/9_1/", title: "最后一本")
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [ExploreTestData.category],
                selectedCategory: ExploreTestData.category,
                books: pageOne,
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                await recorder.recordBooks(title: category.title, page: page)
                return [lastBook]
            }
        }

        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreLoaded([lastBook], page: 2)) {
            $0.books = pageOne + [lastBook]
            $0.page = 2
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        // 不足一页 ⇒ hasMore = false ⇒ 再触发是 no-op（不改变状态，故不传尾随闭包）。
        await store.send(.loadMore)
        await store.finish()

        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [2], "末页之后不得再发请求")
    }
}

/// 记录书城依赖收到的调用，供测试在 `store.finish()` 后断言。
private actor ExploreCallRecorder {
    private var categoriesCalls = 0
    private var booksCalls: [(title: String, page: Int)] = []
    private var savedBatches: [[ExploreCategory]] = []

    func recordCategories() {
        categoriesCalls += 1
    }

    func recordBooks(title: String, page: Int) {
        booksCalls.append((title, page))
    }

    func recordSave(_ categories: [ExploreCategory]) {
        savedBatches.append(categories)
    }

    func categoryCallCount() -> Int {
        categoriesCalls
    }

    func saveBatches() -> [[ExploreCategory]] {
        savedBatches
    }

    func bookCalls() -> [(title: String, page: Int)] {
        booksCalls
    }

    func pageNumbers() -> [Int] {
        booksCalls.map(\.page)
    }
}
