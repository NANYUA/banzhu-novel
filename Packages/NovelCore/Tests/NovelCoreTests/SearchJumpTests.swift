import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 搜索「跳页」的 reducer 行为：`.jumpToPage` 用指定页码的结果替换当前结果，
/// 失败时清空结果并报错。
///
/// 拆到独立文件的原因：`SearchPaginationTests` 的类型体已到 SwiftLint `type_body_length`
/// 250 行 warning 线（CI 用 `--strict`，warning 即失败）。
@MainActor
final class SearchJumpTests: XCTestCase {
    /// 造一个搜索 store：`pages[0]` 是第 1 页、`pages[1]` 是第 2 页……。
    ///
    /// 页码超出数组长度时返回**空页**（等价于「没有这一页」）。
    private func makeStore(pages: [[Book]]) -> TestStore<SearchFeature.State, SearchFeature.Action> {
        TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.searchService.search = { _, page in
                page >= 1 && page <= pages.count ? pages[page - 1] : []
            }
        }
    }

    func test跳页用指定页替换结果并维护页码起始() async {
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
        await store.send(.jumpToPage(2)) {
            $0.results = []
            $0.isLoading = true
            $0.page = 2
            $0.pageStarts = []
            $0.hasMore = false
        }
        await store.receive(.jumpedToPage(pageTwo, page: 2)) {
            $0.results = pageTwo
            $0.isLoading = false
            $0.page = 2
            // 跳页后整份结果被替换 ⇒ 第 2 页的第一本书落在下标 0。
            $0.pageStarts = [SearchPageStart(page: 2, index: 0)]
            $0.hasMore = false
        }
        await store.finish()
    }

    func test跳页失败清空结果并报错() async {
        let pageOne = (0 ..< 30).map { Book(path: "/1/\($0)/", title: "第 \($0) 本") }
        let store = TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.searchService.search = { _, page in
                if page >= 2 {
                    throw JumpFailed()
                }
                return pageOne
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
            $0.hasMore = false
        }
        await store.receive(.searchSucceeded(pageOne)) {
            $0.results = pageOne
            $0.isLoading = false
            $0.page = 1
            $0.pageStarts = [SearchPageStart(page: 1, index: 0)]
            $0.hasMore = true
        }
        await store.send(.jumpToPage(2)) {
            $0.results = []
            $0.isLoading = true
            $0.page = 2
            $0.pageStarts = []
            $0.hasMore = false
        }
        await store.receive(.jumpFailed("跳页失败。")) {
            $0.results = []
            $0.isLoading = false
            $0.errorMessage = "跳页失败。"
        }
        await store.finish()
    }
}

/// 跳页用例专用的失败类型。
private struct JumpFailed: LocalizedError {
    var errorDescription: String? {
        "跳页失败。"
    }
}
