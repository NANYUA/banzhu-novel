import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 失败与重试的回归测试。
///
/// 三类失败必须分开处理：分类没拿到、首屏书目失败都是**整页失败**（写 `errorMessage`），
/// 「加载更多」失败是**局部失败**（写 `moreErrorMessage`）—— 后者不得把已经加载好的书目
/// 换成失败页，而且 `.retry` 必须重发**失败的那一步**：翻页失败就重发同一页，
/// 不许退回第 1 页。夹具与调用记录器见 `ExploreTestSupport.swift`。
@MainActor
final class ExploreFailureTests: XCTestCase {
    // MARK: - 失败态下的重试：必须给 loading，且重发的是「失败的那一步」

    /// 失败态下的 `.retry` **必须**给 loading 反馈 —— 哪怕手上已经有分类。
    /// 这条同时钉住「静默刷新只属于 `.task`」：重试是用户显式动作，不能被悄悄降级成静默刷新。
    func test失败态下重试仍然进入加载态() async {
        let stale = [ExploreTestData.category]
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: stale,
                errorMessage: "分类加载失败：连接超时。",
                failedStep: .categories
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            // 缓存命中：不该走网络。
            $0.exploreCategoryStore.load = { stale }
            $0.exploreService.categories = { stale }
        }

        await store.send(.retry) {
            $0.isLoading = true
            $0.errorMessage = nil
            $0.failedStep = nil
        }
        await store.receive(.categoriesLoaded(stale)) {
            $0.isLoading = false
        }
        await store.finish()

        XCTAssertFalse(store.state.isLoading, "重试完成后必须复位 loading")
    }

    func test首屏书目失败后重试仍重拉第1页() async {
        let pageOne = ExploreTestData.fullPage(1)
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(categories: [ExploreTestData.category])
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
                return pageOne
            }
        }

        await recorder.failBookCalls(1)

        await store.send(.categorySelected(ExploreTestData.category)) {
            $0.selectedCategory = ExploreTestData.category
            $0.isLoading = true
        }
        await store.receive(.booksFailed("书目加载失败：网络不可用。")) {
            $0.isLoading = false
            $0.errorMessage = "书目加载失败：网络不可用。"
            $0.failedStep = .firstPage
        }
        await store.send(.retry) {
            $0.isLoading = true
            $0.errorMessage = nil
            $0.failedStep = nil
        }
        await store.receive(.booksLoaded(pageOne)) {
            $0.books = pageOne
            $0.isLoading = false
            $0.hasMore = true
        }
        await store.finish()

        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [1, 1], "首屏失败后的重试仍然是第 1 页")
        XCTAssertEqual(store.state.books, pageOne, "重试成功后书目要回来")
        XCTAssertNil(store.state.errorMessage)
    }

    // MARK: - 「加载更多」失败：局部失败（不清空已加载的书、不写整页错误）

    func test加载更多失败不清空书目也不写整页错误() async {
        let pageOne = ExploreTestData.fullPage(1)
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
                try await recorder.recordBooks(title: category.title, page: page)
                return []
            }
        }

        await recorder.failBookCalls(1)

        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreFailed("加载更多失败：网络不可用。")) {
            $0.moreErrorMessage = "加载更多失败：网络不可用。"
            $0.failedStep = .more
            $0.isLoadingMore = false
        }
        await store.finish()

        XCTAssertEqual(store.state.books, pageOne, "翻页失败不得动已经加载好的书目")
        XCTAssertNil(store.state.errorMessage, "局部失败不得写整页错误 —— 那会把整份书目换成失败页")
        XCTAssertEqual(store.state.moreErrorMessage, "加载更多失败：网络不可用。")
        XCTAssertFalse(store.state.isLoadingMore, "失败后必须复位 isLoadingMore")
        XCTAssertEqual(store.state.page, 1, "失败不推进页码，重试仍从这一页往后")
    }

    func test加载更多失败后重试重发同一页而不是回第1页() async {
        let loaded = ExploreTestData.fullPage(1) + ExploreTestData.fullPage(2) + ExploreTestData.fullPage(3)
        let pageFour = [Book(path: "/book/4_1/", title: "示例书 4-1")]
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [ExploreTestData.category],
                selectedCategory: ExploreTestData.category,
                books: loaded,
                page: 3,
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
                return pageFour
            }
        }

        await recorder.failBookCalls(1) // 第 4 页的第一次请求失败

        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreFailed("加载更多失败：网络不可用。")) {
            $0.moreErrorMessage = "加载更多失败：网络不可用。"
            $0.failedStep = .more
            $0.isLoadingMore = false
        }
        // 重试：派发时清掉局部失败并重新置加载中，**不碰** `books` / `page`。
        await store.send(.retry) {
            $0.moreErrorMessage = nil
            $0.failedStep = nil
            $0.isLoadingMore = true
        }
        await store.receive(.moreLoaded(pageFour, page: 4)) {
            $0.books = loaded + pageFour
            $0.page = 4
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        await store.finish()

        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [4, 4], "重试必须重发同一页（第 4 页）；序列里出现 1 就说明被打回了第 1 页")
        XCTAssertEqual(store.state.page, 4, "重试成功后页码要前进到第 4 页")
        XCTAssertNil(store.state.moreErrorMessage, "成功后局部错误必须清空")
        XCTAssertNil(store.state.errorMessage, "整个过程都不得出现整页失败态")
        XCTAssertEqual(store.state.books, loaded + pageFour, "已加载的后 3 页必须原样保留")
    }

    func test加载下一页成功后清空局部错误() async {
        let pageOne = ExploreTestData.fullPage(1)
        let pageTwo = [Book(path: "/book/2_1/", title: "示例书 2-1")]
        // ⚠️ 这里**直接**发 `.moreLoaded`（不经过 `.loadMore`）：派发那一处已经清过一次局部错误，
        // 那条路径上「成功即清空」是顺带的。本测试钉的是 `.moreLoaded` **自己**也会清 ——
        // 有人把派发处的清理挪走时，这条断言才会红。
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [ExploreTestData.category],
                moreErrorMessage: "加载更多失败：网络不可用。",
                failedStep: .more,
                selectedCategory: ExploreTestData.category,
                books: pageOne,
                isLoadingMore: true,
                hasMore: true
            )
        ) {
            ExploreFeature()
        }

        await store.send(.moreLoaded(pageTwo, page: 2)) {
            $0.books = pageOne + pageTwo
            $0.page = 2
            $0.isLoadingMore = false
            $0.hasMore = false
            $0.moreErrorMessage = nil
            $0.failedStep = nil
        }
        await store.finish()

        XCTAssertNil(store.state.moreErrorMessage, "下一页加载成功后旧错误不得粘着")
        XCTAssertNil(store.state.failedStep, "失败步骤也要一起清掉，否则 `.retry` 还会重发这一页")
        XCTAssertEqual(store.state.books, pageOne + pageTwo)
    }
}
