import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 搜索分页的 reducer 行为：`.pageStarts`（每一页第一本书的**页码 + 下标**）怎么维护。
///
/// 拆到独立文件的原因：`SearchFeatureTests` 的类型体已经超过 SwiftLint `type_body_length`
/// 的 250 行 warning 线（CI 用 `--strict`，warning 即失败）。
@MainActor
final class SearchPaginationTests: XCTestCase {
    /// 造一个搜索 store：`pages[0]` 是第 1 页、`pages[1]` 是第 2 页……。
    ///
    /// 页码超出数组长度时返回**空页**（等价于「没有下一页」）。
    /// 内联而不是抽到 `XCTestCase` 的公共基类：本包现有测试都是自包含的。
    private func makeStore(pages: [[Book]]) -> TestStore<SearchFeature.State, SearchFeature.Action> {
        TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.searchService.search = { _, page in
                page >= 1 && page <= pages.count ? pages[page - 1] : []
            }
        }
    }

    func test搜索可分页追加下一页() async {
        let pageOne = (0 ..< 30).map { Book(path: "/1/\($0)/", title: "第 \($0) 本") }
        let pageTwo = [Book(path: "/2/1/", title: "第二页第一本")]
        let store = makeStore(pages: [pageOne, pageTwo])

        await store.send(.keywordChanged("示例")) {
            $0.keyword = "示例"
        }
        await store.send(.search) {
            $0.submittedKeyword = "示例"
            $0.isLoading = true
            $0.page = 1
            $0.pageStarts = []
            $0.hasMore = false
        }
        await store.receive(.searchSucceeded(pageOne)) {
            $0.results = pageOne
            $0.isLoading = false
            $0.page = 1
            $0.pageStarts = [SearchPageStart(page: 1, index: 0)]
            $0.hasMore = true
        }
        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreSucceeded(pageTwo, page: 2)) {
            $0.results = pageOne + pageTwo
            $0.page = 2
            // 第 2 页的第一本书落在下标 30（第 1 页满 30 本）⇒ 视图侧在它之前插「第 2 页」。
            $0.pageStarts = [SearchPageStart(page: 1, index: 0), SearchPageStart(page: 2, index: 30)]
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        await store.finish()
    }

    func test下一页与已加载重复时不记页起始下标() async {
        let pageOne = (0 ..< 30).map { Book(path: "/1/\($0)/", title: "第 \($0) 本") }
        // 第 2 页只回来 2 本，且都已在第 1 页里（服务端换页时常见的重叠）。
        let pageTwo = [pageOne[29], Book(path: "/2/1/", title: "第二页第一本")]
        let store = makeStore(pages: [pageOne, pageTwo])

        await store.send(.keywordChanged("示例")) {
            $0.keyword = "示例"
        }
        await store.send(.search) {
            $0.submittedKeyword = "示例"
            $0.isLoading = true
            $0.page = 1
            $0.pageStarts = []
            $0.hasMore = false
        }
        await store.receive(.searchSucceeded(pageOne)) {
            $0.results = pageOne
            $0.isLoading = false
            $0.page = 1
            $0.pageStarts = [SearchPageStart(page: 1, index: 0)]
            $0.hasMore = true
        }
        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreSucceeded(pageTwo, page: 2)) {
            // 重复的那本被滤掉 ⇒ 真正追加进去的只有 `/2/1/`，它落在下标 30。
            // 若把起始下标记在**过滤前**的 `books.count` 上，标签就会插到别的书前面。
            $0.results = pageOne + [pageTwo[1]]
            $0.page = 2
            $0.pageStarts = [SearchPageStart(page: 1, index: 0), SearchPageStart(page: 2, index: 30)]
            $0.isLoadingMore = false
            // 服务端这一页只回来 2 本 ⇒ 没有下一页。
            $0.hasMore = false
        }
        await store.finish()
    }

    /// 钉住「页码必须跟下标一起记」：整页都是重复的那一页不记，
    /// 但它**后面**真实落地的那一页仍要显示自己的真实页号。
    ///
    /// 若视图层用 `pageStarts` 的数组下标 +1 推算页号，第 3 页的书会被标成「第 2 页」——
    /// 而需求 2 的全部意义就是「提醒我下面的书是第几页的内容」，数字错就等于功能错。
    func test整页重复时后面一页仍显示真实页号() async {
        let pageOne = (0 ..< 30).map { Book(path: "/1/\($0)/", title: "第 \($0) 本") }
        // 第 2 页整页都是第 1 页已经给过的书（服务端分页把同一批又返回一次）。
        let pageTwo = Array(pageOne[0 ..< 30])
        let pageThree = [Book(path: "/3/1/", title: "第三页第一本")]
        let store = makeStore(pages: [pageOne, pageTwo, pageThree])

        await store.send(.keywordChanged("示例")) {
            $0.keyword = "示例"
        }
        await store.send(.search) {
            $0.submittedKeyword = "示例"
            $0.isLoading = true
            $0.page = 1
            $0.pageStarts = []
            $0.hasMore = false
        }
        await store.receive(.searchSucceeded(pageOne)) {
            $0.results = pageOne
            $0.isLoading = false
            $0.page = 1
            $0.pageStarts = [SearchPageStart(page: 1, index: 0)]
            $0.hasMore = true
        }
        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreSucceeded(pageTwo, page: 2)) {
            // 整页重复 ⇒ 一本都没追加、也**不记**这一页的起始下标。
            $0.results = pageOne
            $0.page = 2
            $0.pageStarts = [SearchPageStart(page: 1, index: 0)]
            $0.isLoadingMore = false
            // 服务端这一页满 30 本 ⇒ 仍按「可能有下一页」放行。
            $0.hasMore = true
        }
        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreSucceeded(pageThree, page: 3)) {
            $0.results = pageOne + pageThree
            $0.page = 3
            // 🔴 记的是 `page: 3`（真实页号），不是 `pageStarts.count + 1 = 2`。
            $0.pageStarts = [SearchPageStart(page: 1, index: 0), SearchPageStart(page: 3, index: 30)]
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        await store.finish()
    }

    /// 需求（owner 2026-10-11 拍板）：加载下一页**失败**时，加载行要变成可点的重试入口。
    ///
    /// 钉住三件事：`.moreFailed` 置位 ⇒ 重试按钮出现；**再点一次 `.loadMore` 就是重试**
    /// （重发同一页，不跳页、不重置已加载的书）；成功后复位 ⇒ 按钮消失。
    func test加载下一页失败后置位可重试成功后复位() async {
        let pageOne = (0 ..< 30).map { Book(path: "/1/\($0)/", title: "第 \($0) 本") }
        let pageTwo = (0 ..< 30).map { Book(path: "/2/\($0)/", title: "第二页第 \($0) 本") }
        // 第 2 页第一次请求失败（`shouldFail` 只在第一次为 true），重试时正常返回。
        let shouldFail = LockIsolated(true)
        let store = TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.searchService.search = { _, page in
                if page == 2, shouldFail.value {
                    shouldFail.setValue(false)
                    throw LoadMoreFailed()
                }
                return page == 1 ? pageOne : pageTwo
            }
        }

        await store.send(.keywordChanged("示例")) {
            $0.keyword = "示例"
        }
        await store.send(.search) {
            $0.submittedKeyword = "示例"
            $0.isLoading = true
            $0.page = 1
            $0.pageStarts = []
            $0.loadMoreFailed = false
            $0.hasMore = false
        }
        await store.receive(.searchSucceeded(pageOne)) {
            $0.results = pageOne
            $0.isLoading = false
            $0.page = 1
            $0.pageStarts = [SearchPageStart(page: 1, index: 0)]
            $0.loadMoreFailed = false
            $0.hasMore = true
        }
        await store.send(.loadMore) {
            $0.isLoadingMore = true
            $0.loadMoreFailed = false
            $0.notice = nil
        }
        await store.receive(.moreFailed("加载下一页失败。")) {
            $0.isLoadingMore = false
            // 🔴 失败态：列表底部那一行变成可点的「加载失败，点一下重试」。
            $0.loadMoreFailed = true
            $0.notice = "加载下一页失败。"
        }
        await retrySucceeding(store, pageOne: pageOne, pageTwo: pageTwo)
    }

    /// 失败之后的那次「重试 = 再发一次 `.loadMore`」：重发**同一页**（`page` 没前进），
    /// 成功后复位。单独一个函数只为压住 `function_body_length`，断言与上面那支同属一个用例。
    private func retrySucceeding(
        _ store: TestStore<SearchFeature.State, SearchFeature.Action>,
        pageOne: [Book],
        pageTwo: [Book]
    ) async {
        await store.send(.loadMore) {
            $0.isLoadingMore = true
            $0.loadMoreFailed = false
            $0.notice = nil
        }
        await store.receive(.moreSucceeded(pageTwo, page: 2)) {
            $0.results = pageOne + pageTwo
            $0.page = 2
            $0.pageStarts = [SearchPageStart(page: 1, index: 0), SearchPageStart(page: 2, index: 30)]
            $0.isLoadingMore = false
            $0.loadMoreFailed = false
            $0.hasMore = true
        }
        await store.finish()
    }
}

/// 上面那个用例专用的失败类型（`LocalizedError` 的 `errorDescription` 就是 `.notice` 里的文案）。
private struct LoadMoreFailed: LocalizedError {
    var errorDescription: String? {
        "加载下一页失败。"
    }
}
