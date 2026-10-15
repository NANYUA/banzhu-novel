import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 失败与重试的回归测试。
///
/// 首屏书目失败是**整页失败**（写 `errorMessage`），「加载更多」失败是**局部失败**
/// （写 `moreErrorMessage`）—— 后者不得把已经加载好的书目换成失败页，
/// 而且 `.retry` 必须重发同一页，不许退回第 1 页。夹具见 `ExploreTestSupport.swift`。
@MainActor
final class ExploreFailureTests: XCTestCase {
    // MARK: - 失败态下的重试：必须给 loading，且重发的是「失败的那一步」

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
            $0.requestID = 1
        }
        await store.receive(.booksFailed("书目加载失败：网络不可用。", requestID: 1)) {
            $0.isLoading = false
            $0.errorMessage = "书目加载失败：网络不可用。"
            $0.failedStep = .firstPage
        }
        await store.send(.retry) {
            $0.isLoading = true
            $0.errorMessage = nil
            $0.failedStep = nil
            $0.requestID = 2
        }
        await store.receive(.booksLoaded(pageOne, requestID: 2)) {
            $0.books = pageOne
            $0.isLoading = false
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0)]
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

        await recorder.failBookCalls(1)

        await store.send(.loadMore) {
            $0.isLoadingMore = true
            $0.requestID = 1
        }
        await store.receive(.moreFailed("加载更多失败：网络不可用。", requestID: 1)) {
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
        XCTAssertEqual(store.state.pageStarts, [ExplorePageStart(page: 1, index: 0)], "翻页失败保留已有页码标签")
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
                pageStarts: ExploreTestData.pageStarts([(1, 0), (2, 30), (3, 60)]),
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
            $0.requestID = 1
        }
        await store.receive(.moreFailed("加载更多失败：网络不可用。", requestID: 1)) {
            $0.moreErrorMessage = "加载更多失败：网络不可用。"
            $0.failedStep = .more
            $0.isLoadingMore = false
        }
        // 重试：派发时清掉局部失败并重新置加载中，**不碰** `books` / `page`。
        await store.send(.retry) {
            $0.moreErrorMessage = nil
            $0.failedStep = nil
            $0.isLoadingMore = true
            $0.requestID = 2
        }
        await store.receive(.moreLoaded(pageFour, page: 4, requestID: 2)) {
            $0.books = loaded + pageFour
            $0.page = 4
            $0.pageStarts = ExploreTestData.pageStarts([(1, 0), (2, 30), (3, 60), (4, 90)])
            $0.isLoadingMore = false
            $0.hasMore = true
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
                pageStarts: [ExplorePageStart(page: 1, index: 0)],
                requestID: 1,
                isLoadingMore: true,
                hasMore: true
            )
        ) {
            ExploreFeature()
        }

        await store.send(.moreLoaded(pageTwo, page: 2, requestID: 1)) {
            $0.books = pageOne + pageTwo
            $0.page = 2
            $0.pageStarts = [ExplorePageStart(page: 1, index: 0), ExplorePageStart(page: 2, index: 30)]
            $0.isLoadingMore = false
            $0.hasMore = true
            $0.moreErrorMessage = nil
            $0.failedStep = nil
        }
        await store.finish()

        XCTAssertNil(store.state.moreErrorMessage, "下一页加载成功后旧错误不得粘着")
        XCTAssertNil(store.state.failedStep, "失败步骤也要一起清掉，否则 `.retry` 还会重发这一页")
        XCTAssertEqual(store.state.books, pageOne + pageTwo)
    }

    // MARK: - 跳页失败：整页失败，`.retry` 重跳同一页

    func test跳页失败后重试仍跳同一页() async {
        let selected = ExploreTestData.category
        let pageOne = ExploreTestData.fullPage(1)
        let pageTwo = [Book(path: "/book/2_0/", title: "第二页的书")]
        let recorder = ExploreCallRecorder()
        let store = TestStore(
            initialState: ExploreFeature.State(
                categories: [selected],
                selectedCategory: selected,
                books: pageOne,
                pageStarts: [ExplorePageStart(page: 1, index: 0)],
                hasMore: true
            )
        ) {
            ExploreFeature()
        } withDependencies: {
            $0.exploreService.books = { category, page in
                try await recorder.recordBooks(title: category.title, page: page)
                return page == 2 ? pageTwo : pageOne
            }
        }

        await recorder.failBookCalls(1)

        await store.send(.jumpToPage(2)) {
            $0.books = []
            $0.page = 2
            $0.pageStarts = []
            $0.hasMore = false
            $0.isLoading = true
            $0.requestID = 1
        }
        await store.receive(.jumpFailed("书目加载失败：网络不可用。", page: 2, requestID: 1)) {
            $0.isLoading = false
            $0.errorMessage = "书目加载失败：网络不可用。"
            $0.failedStep = .jump(page: 2)
        }
        await store.send(.retry) {
            $0.isLoading = true
            $0.errorMessage = nil
            $0.failedStep = nil
            $0.requestID = 2
        }
        await store.receive(.jumpedToPage(pageTwo, page: 2, requestID: 2)) {
            $0.books = pageTwo
            $0.isLoading = false
            $0.page = 2
            $0.pageStarts = [ExplorePageStart(page: 2, index: 0)]
            $0.hasMore = true
        }
        await store.finish()

        let pages = await recorder.pageNumbers()
        XCTAssertEqual(pages, [2, 2], "跳页失败后的重试仍应请求同一页码")
    }
}
