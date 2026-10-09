import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

@MainActor
final class SearchFeatureTests: XCTestCase {
    private static let book = Book(path: "/1/", title: "示例书")
    private static let row = ShelfRow(
        bookPath: "/1/",
        title: "示例书",
        author: "某某某",
        coverUrl: "",
        latestChapterName: "第三章",
        unreadCount: 3
    )

    func test输入关键词后提交搜索并填入结果() async {
        let recorder = SearchCallRecorder()
        let store = TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.searchService.search = { keyword, page in
                // 🔴 不要在 effect 闭包里直接 XCTAssert：它在后台任务上执行，
                // 失败会挂到不相关的用例上。先记录，store.finish() 后再断言。
                await recorder.record(keyword: keyword, page: page)
                return [Self.book]
            }
        }

        await store.send(.keywordChanged("示例")) {
            $0.keyword = "示例"
        }
        await store.send(.search) {
            $0.submittedKeyword = "示例"
            $0.isLoading = true
        }
        await store.receive(.searchSucceeded([Self.book])) {
            $0.results = [Self.book]
            $0.isLoading = false
            $0.hasMore = false
        }
        await store.finish()
        let call = await recorder.last()
        XCTAssertEqual(
            call?.keyword,
            "示例",
            "首页搜索的 keyword 应为「示例」，实际收到「\(call?.keyword ?? "nil")」"
        )
        XCTAssertEqual(call?.page, 1, "首页搜索的 page 应为 1，实际收到 \(call?.page as Any)")
    }

    func test空关键词不会发起搜索() async {
        let store = TestStore(initialState: SearchFeature.State(keyword: "   ")) {
            SearchFeature()
        }

        await store.send(.search) {
            $0.errorMessage = "请输入书名或作者名。"
        }
        await store.finish()
    }

    func test搜索失败清空旧结果并保留错误() async {
        struct SearchFailed: LocalizedError {
            var errorDescription: String? {
                "搜索服务暂时不可用。"
            }
        }

        let store = TestStore(initialState: SearchFeature.State(keyword: "示例", results: [Self.book])) {
            SearchFeature()
        } withDependencies: {
            $0.searchService.search = { _, _ in throw SearchFailed() }
        }

        await store.send(.search) {
            $0.submittedKeyword = "示例"
            $0.isLoading = true
            $0.errorMessage = nil
            $0.notice = nil
        }
        await store.receive(.searchFailed("搜索服务暂时不可用。")) {
            $0.results = []
            $0.isLoading = false
            $0.errorMessage = "搜索服务暂时不可用。"
        }
        await store.finish()
    }

    func test加入书架成功后显示提示() async {
        let store = TestStore(initialState: SearchFeature.State(results: [Self.book])) {
            SearchFeature()
        } withDependencies: {
            $0.shelfAdder.add = { _ in Self.row }
        }

        await store.send(.addRequested(Self.book)) {
            $0.addingPaths = [Self.book.path]
        }
        await store.receive(.addSucceeded(Self.row)) {
            $0.addingPaths = []
            $0.addedPaths = [Self.book.path]
            $0.notice = "《示例书》已加入书架。"
            $0.lastAddedRow = Self.row
        }
        await store.finish()
    }

    func test重复点击加入不会并发发两次() async {
        let store = TestStore(
            initialState: SearchFeature.State(results: [Self.book], addingPaths: [Self.book.path])
        ) {
            SearchFeature()
        }

        await store.send(.addRequested(Self.book))
        await store.finish()
    }

    func test已加入的书不会再次发请求() async {
        let store = TestStore(
            initialState: SearchFeature.State(
                results: [Self.book],
                addedPaths: [Self.book.path]
            )
        ) {
            SearchFeature()
        }

        await store.send(.addRequested(Self.book))
        await store.finish()
    }

    func test搜索可分页追加下一页() async {
        let pageOne = (0 ..< 30).map { Book(path: "/1/\($0)/", title: "第 \($0) 本") }
        let pageTwo = [Book(path: "/2/1/", title: "第二页第一本")]
        let store = TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.searchService.search = { _, page in
                page == 1 ? pageOne : pageTwo
            }
        }

        await store.send(.keywordChanged("示例")) {
            $0.keyword = "示例"
        }
        await store.send(.search) {
            $0.submittedKeyword = "示例"
            $0.isLoading = true
            $0.page = 1
            $0.hasMore = false
        }
        await store.receive(.searchSucceeded(pageOne)) {
            $0.results = pageOne
            $0.isLoading = false
            $0.page = 1
            $0.hasMore = true
        }
        await store.send(.loadMore) {
            $0.isLoadingMore = true
        }
        await store.receive(.moreSucceeded(pageTwo, page: 2)) {
            $0.results = pageOne + pageTwo
            $0.page = 2
            $0.isLoadingMore = false
            $0.hasMore = false
        }
        await store.finish()
    }

    func test加入失败清除该书加载态并显示人话提示() async {
        let store = TestStore(initialState: SearchFeature.State(results: [Self.book])) {
            SearchFeature()
        } withDependencies: {
            $0.shelfAdder.add = { _ in
                throw ShelfAdderError.alreadyExists(title: "示例书")
            }
        }

        await store.send(.addRequested(Self.book)) {
            $0.addingPaths = [Self.book.path]
        }
        await store.receive(.addFailed(bookPath: Self.book.path, message: "《示例书》已经在书架里了。")) {
            $0.addingPaths = []
            $0.notice = "《示例书》已经在书架里了。"
        }
        await store.finish()
    }

    func test加入失败只清除当前书的加载态() async {
        let otherBook = Book(path: "/2/", title: "另一本书")
        let store = TestStore(
            initialState: SearchFeature.State(
                results: [Self.book, otherBook],
                addingPaths: [Self.book.path, otherBook.path]
            )
        ) {
            SearchFeature()
        }

        await store.send(
            .addFailed(
                bookPath: Self.book.path,
                message: "《示例书》已经在书架里了。"
            )
        ) {
            $0.addingPaths = [otherBook.path]
            $0.notice = "《示例书》已经在书架里了。"
        }
        await store.finish()
    }
}

/// 记录搜索服务收到的调用，供测试在 `store.finish()` 后断言。
private actor SearchCallRecorder {
    private var calls: [(keyword: String, page: Int)] = []

    func record(keyword: String, page: Int) {
        calls.append((keyword, page))
    }

    func last() -> (keyword: String, page: Int)? {
        calls.last
    }
}
