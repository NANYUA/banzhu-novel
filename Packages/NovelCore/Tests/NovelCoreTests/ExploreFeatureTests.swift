import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 书城的分类与首屏书目加载（`.task` / 选分类 / 首屏失败）。
///
/// 夹具与调用记录器见 `ExploreTestSupport.swift`；分页用例见 `ExplorePagingTests`；
/// 失败与重试的用例见 `ExploreFailureTests`（拆开是为了守住 `file_length` 与 `type_body_length`）。
@MainActor
final class ExploreFeatureTests: XCTestCase {
    func test首次进入同步提供固定分类并自动加载默认组合() async {
        let firstPage = [Book(path: "/book/default/", title: "默认书目")]
        let recorder = ExploreCallRecorder()
        let store = TestStore(initialState: ExploreFeature.State()) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreCategoryStore.load = {
                XCTFail("固定分类不得读取旧缓存")
                return nil
            }
            $0.exploreCategoryStore.save = { _ in XCTFail("固定分类不得写入旧缓存") }
            $0.exploreService.categories = {
                XCTFail("固定分类不得请求站点首页")
                return []
            }
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
                XCTAssertEqual(category.url(page: page), "/shuku/0-lastupdate-0-1.html")
                return firstPage
            }
        }

        await store.send(.task) {
            $0.categories = ExploreCategoryCatalog.allItems
            $0.selectedCategory = ExploreCategoryCatalog.defaultCategory
            $0.isLoading = true
            $0.requestID = 1
        }
        await store.receive(.booksLoaded(firstPage, requestID: 1)) {
            $0.books = firstPage
            $0.isLoading = false
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0)]
            $0.hasMore = true
        }
        await store.finish()
        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [1])
    }

    func test切回页面保留书目和页码不重新请求() async {
        let selected = ExploreCategoryCatalog.defaultCategory
        let books = ExploreTestData.fullPage(1)
        let recorder = ExploreCallRecorder()
        let store = TestStore(initialState: ExploreFeature.State(
            selectedCategory: selected,
            books: books,
            page: 2,
            pageStarts: [ExplorePageStart(page: 1, index: 0)],
            hasMore: true
        )) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreCategoryStore.load = {
                XCTFail("切回页面不得读缓存")
                return nil
            }
            $0.exploreCategoryStore.save = { _ in XCTFail("切回页面不得写缓存") }
            $0.exploreService.categories = {
                XCTFail("切回页面不得请求首页")
                return []
            }
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
                return []
            }
        }

        await store.send(.task) { $0.categories = ExploreCategoryCatalog.allItems }
        await store.send(.task)
        await store.finish()
        XCTAssertEqual(store.state.books, books)
        XCTAssertEqual(store.state.page, 2)
        XCTAssertTrue(store.state.hasMore)
        let calls = await recorder.bookCalls()
        XCTAssertTrue(calls.isEmpty)
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
                try await recorder.recordBooks(title: category.title, page: page)
                return [book]
            }
        }

        await store.send(.categorySelected(ExploreTestData.category)) {
            $0.selectedCategory = ExploreTestData.category
            $0.isLoading = true
            $0.requestID = 1
        }
        await store.receive(.booksLoaded([book], requestID: 1)) {
            $0.books = [book]
            $0.isLoading = false
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0)]
            $0.hasMore = true
        }
        await store.finish()

        let calls = await recorder.bookCalls()
        XCTAssertEqual(calls.first?.title, "示例分类")
        XCTAssertEqual(calls.first?.page, 1, "选中分类应拉第 1 页")
    }

    func test切换分类清空旧书目与页码标签() async {
        let previous = ExploreTestData.category
        let next = ExploreCategoryCatalog.category(
            status: ExploreCategoryCatalog.statuses[1],
            sort: ExploreCategoryCatalog.sorts[2],
            genre: ExploreCategoryCatalog.genres[3]
        )
        let oldBooks = ExploreTestData.fullPage(1) + ExploreTestData.fullPage(2)
        let newBook = Book(path: "/book/new/", title: "新分类")
        let store = TestStore(initialState: ExploreFeature.State(
            categories: ExploreCategoryCatalog.allItems,
            moreErrorMessage: "旧分类翻页失败",
            failedStep: .more,
            selectedCategory: previous,
            books: oldBooks,
            page: 2,
            pageStarts: [ExplorePageStart(page: 1, index: 0), ExplorePageStart(page: 2, index: 30)],
            requestID: 3,
            hasMore: true
        )) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                XCTAssertEqual(category.url(page: page), "/shuku/3-monthvisit-1-1.html")
                return [newBook]
            }
        }

        await store.send(.categorySelected(next)) {
            $0.selectedCategory = next
            $0.books = []
            $0.page = 1
            $0.pageStarts = []
            $0.hasMore = false
            $0.isLoading = true
            $0.requestID = 4
            $0.moreErrorMessage = nil
            $0.failedStep = nil
        }
        await store.receive(.booksLoaded([newBook], requestID: 4)) {
            $0.books = [newBook]
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0)]
            $0.isLoading = false
            $0.hasMore = true
        }
        await store.finish()
    }

    func test旧分类首屏结果与失败不得覆盖新分类() async {
        let current = ExploreCategoryCatalog.defaultCategory
        let book = Book(path: "/book/current/", title: "当前分类")
        let store = TestStore(initialState: ExploreFeature.State(
            isLoading: true,
            selectedCategory: current,
            requestID: 2
        )) {
            ExploreFeature()
        }
        await store.send(.booksLoaded([Book(path: "/book/old/", title: "旧分类")], requestID: 1))
        await store.send(.booksFailed("旧分类失败", requestID: 1))
        await store.send(.booksLoaded([book], requestID: 2)) {
            $0.books = [book]
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0)]
            $0.isLoading = false
        }
        await store.finish()
    }

    // MARK: - ⑤ 失败路径：写 errorMessage 且复位 loading

    func test书目加载失败写入错误文案并复位加载态() async {
        let store = TestStore(
            initialState: ExploreFeature.State(categories: [ExploreTestData.category])
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { _, _ in throw ExploreTestFailure() }
        }

        await store.send(.categorySelected(ExploreTestData.category)) {
            $0.selectedCategory = ExploreTestData.category
            $0.isLoading = true
            $0.requestID = 1
        }
        await store.receive(.booksFailed("书目加载失败：网络不可用。", requestID: 1)) {
            $0.isLoading = false
            $0.errorMessage = "书目加载失败：网络不可用。"
            $0.failedStep = .firstPage
        }
        await store.finish()

        XCTAssertFalse(store.state.isLoading, "失败后必须复位 loading")
    }
}

/// 分页：追加、加载中 no-op、末页判据。
/// 「加载更多」**失败与重试**的用例在 `ExploreFailureTests`（局部失败语义另立一处）。
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
                pageStarts: [ExplorePageStart(page: 1, index: 0)],
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
                return pageTwo
            }
        }

        await store.send(.loadMore) {
            $0.isLoadingMore = true
            $0.requestID = 1
        }
        await store.receive(.moreLoaded(pageTwo, page: 2, requestID: 1)) {
            $0.books = pageOne + pageTwo
            $0.page = 2
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0), ExplorePageStart(page: 2, index: 30)]
            $0.isLoadingMore = false
            $0.hasMore = true
        }
        await store.finish()

        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [2], "下一页应请求第 2 页")
    }

    func test分页去重后页码标签指向首本新书() async {
        let first = ExploreTestData.fullPage(1)
        let newBook = Book(path: "/book/new/", title: "第二页新增")
        let response = [first[0], newBook]
        let store = TestStore(initialState: ExploreFeature.State(
            selectedCategory: ExploreTestData.category,
            books: first,
            pageStarts: [ExplorePageStart(page: 1, index: 0)],
            hasMore: true
        )) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { _, _ in response }
        }

        await store.send(.loadMore) {
            $0.isLoadingMore = true
            $0.requestID = 1
        }
        await store.receive(.moreLoaded(response, page: 2, requestID: 1)) {
            $0.books = first + [newBook]
            $0.page = 2
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0), ExplorePageStart(page: 2, index: 30)]
            $0.isLoadingMore = false
            $0.hasMore = true
        }
        await store.finish()
    }

    func test旧分类同页结果与失败不打断当前分页() async {
        let first = ExploreTestData.fullPage(1)
        let next = [Book(path: "/book/current/", title: "当前第二页")]
        let store = TestStore(initialState: ExploreFeature.State(
            selectedCategory: ExploreCategoryCatalog.defaultCategory,
            books: first,
            pageStarts: [ExplorePageStart(page: 1, index: 0)],
            requestID: 2,
            isLoadingMore: true,
            hasMore: true
        )) {
            ExploreFeature()
        }

        await store.send(.moreLoaded([Book(path: "/book/old/", title: "旧分类")], page: 2, requestID: 1))
        await store.send(.moreFailed("旧分类失败", requestID: 1))
        XCTAssertTrue(store.state.isLoadingMore, "旧请求不得复位当前分类的加载态")
        await store.send(.moreLoaded(next, page: 2, requestID: 2)) {
            $0.books = first + next
            $0.page = 2
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0), ExplorePageStart(page: 2, index: 30)]
            $0.isLoadingMore = false
            $0.hasMore = true
        }
        await store.finish()
    }

    func test整页重复仍推进服务端页码不增加标签() async {
        let first = ExploreTestData.fullPage(1)
        let store = TestStore(initialState: ExploreFeature.State(
            selectedCategory: ExploreTestData.category,
            books: first,
            pageStarts: [ExplorePageStart(page: 1, index: 0)],
            requestID: 1,
            isLoadingMore: true,
            hasMore: true
        )) {
            ExploreFeature()
        }
        await store.send(.moreLoaded(first, page: 2, requestID: 1)) {
            $0.page = 2
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        await store.finish()
        XCTAssertEqual(store.state.pageStarts, [ExplorePageStart(page: 1, index: 0)])
    }

    func test加载中重复触发加载下一页是空操作() async {
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [ExploreTestData.category],
                selectedCategory: ExploreTestData.category,
                books: ExploreTestData.fullPage(1),
                pageStarts: [ExplorePageStart(page: 1, index: 0)],
                isLoadingMore: true,
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
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

    func test返回空页视为末页且不再翻页() async {
        let pageOne = ExploreTestData.fullPage(1)
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [ExploreTestData.category],
                selectedCategory: ExploreTestData.category,
                books: pageOne,
                pageStarts: [ExplorePageStart(page: 1, index: 0)],
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
                return []
            }
        }

        await store.send(.loadMore) {
            $0.isLoadingMore = true
            $0.requestID = 1
        }
        await store.receive(.moreLoaded([], page: 2, requestID: 1)) {
            $0.page = 2
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        // 空页 ⇒ hasMore = false ⇒ 再触发是 no-op（不改变状态，故不传尾随闭包）。
        await store.send(.loadMore)
        await store.finish()

        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [2], "末页之后不得再发请求")
    }
}
