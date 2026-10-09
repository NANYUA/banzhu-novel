import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

@MainActor
final class BookDetailFeatureTests: XCTestCase {
    private static let bookPath = "/1/"
    private static let fallback = BookDetail(bookPath: bookPath, title: "搜索结果")
    private static let row = ShelfRow(
        bookPath: bookPath,
        title: "搜索结果",
        author: "某某某",
        coverUrl: "",
        latestChapterName: "第三章",
        unreadCount: 3
    )

    func test加载本地快照覆盖搜索字段() async {
        let local = BookDetail(
            bookPath: Self.bookPath,
            title: "本地书名",
            author: "本地作者",
            intro: "本地简介",
            status: "已完本",
            category: "玄幻",
            tags: ["热血"],
            wordCount: "100万字",
            lastChapter: "第 10 章",
            lastUpdated: "2026-10-09"
        )
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in local }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded(local)) {
            $0.detail = local
            $0.isLoading = false
            // 🔴 本地命中记录 == 已在书架：详情页据此显示「移出书架」。
            $0.isOnShelf = true
        }
        await store.finish()
    }

    func test本地无记录时保留搜索回退值且不在书架() async {
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        XCTAssertEqual(store.state.detail, Self.fallback)
        XCTAssertFalse(store.state.isOnShelf)
        await store.finish()
    }

    func test加载失败时保留回退值并显示错误() async {
        struct Failed: LocalizedError {
            var errorDescription: String? {
                "加载失败"
            }
        }
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in throw Failed() }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loadFailed("加载失败")) {
            $0.isLoading = false
            $0.errorMessage = "加载失败"
        }
        XCTAssertEqual(store.state.detail, Self.fallback)
        XCTAssertFalse(store.state.isOnShelf)
        await store.finish()
    }

    func test加入书架成功后切换为已加入() async {
        struct WrongBook: Error {}
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.shelfAdder.add = { book in
                // 详情页必须把快照还原成引擎书模型走同一条落库路径。
                guard book.path == Self.bookPath, book.title == "搜索结果" else { throw WrongBook() }
                return Self.row
            }
        }

        await store.send(.addRequested) {
            $0.isShelfBusy = true
        }
        await store.receive(.addSucceeded(Self.row)) {
            $0.isShelfBusy = false
            $0.isOnShelf = true
            $0.lastAddedRow = Self.row
        }
        await store.finish()
    }

    func test加入时发现已在书架也切到已加入() async {
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.shelfAdder.add = { _ in
                throw ShelfAdderError.alreadyExists(title: "搜索结果")
            }
        }

        await store.send(.addRequested) {
            $0.isShelfBusy = true
        }
        await store.receive(.addFailed(message: "《搜索结果》已经在书架里了。", alreadyExists: true)) {
            $0.isShelfBusy = false
            $0.shelfNotice = "《搜索结果》已经在书架里了。"
            // 已经在书架里 == 状态其实是「已加入」，按钮不能停在「加入书架」。
            $0.isOnShelf = true
        }
        await store.finish()
    }

    func test加入失败保留未加入状态并显示提示() async {
        struct Failed: LocalizedError {
            var errorDescription: String? {
                "网络不给力"
            }
        }
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.shelfAdder.add = { _ in throw Failed() }
        }

        await store.send(.addRequested) {
            $0.isShelfBusy = true
        }
        await store.receive(.addFailed(message: "网络不给力", alreadyExists: false)) {
            $0.isShelfBusy = false
            $0.shelfNotice = "网络不给力"
        }
        await store.finish()
    }

    func test已在书架时不会重复发加入请求() async {
        var initial = BookDetailFeature.State(fallback: Self.fallback)
        initial.isOnShelf = true
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        }

        // 此时按钮是「移出书架」，`.addRequested` 不应产生任何 effect。
        await store.send(.addRequested)
        await store.finish()
    }

    func test移出书架成功后切回未加入() async {
        struct WrongPath: Error {}
        var initial = BookDetailFeature.State(fallback: Self.fallback)
        initial.isOnShelf = true
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        } withDependencies: {
            $0.shelfGroupStore.removeBooks = { paths in
                // 移出必须复用既有删书路径，并且只针对当前这本书。
                guard paths == [Self.bookPath] else { throw WrongPath() }
            }
        }

        await store.send(.removeRequested) {
            $0.isShelfBusy = true
        }
        await store.receive(.removeSucceeded) {
            $0.isShelfBusy = false
            $0.isOnShelf = false
            $0.lastRemovedPath = Self.bookPath
        }
        await store.finish()
    }

    func test移出书架失败时保留在书架并提示() async {
        struct Failed: LocalizedError {
            var errorDescription: String? {
                "本地数据库写入失败"
            }
        }
        var initial = BookDetailFeature.State(fallback: Self.fallback)
        initial.isOnShelf = true
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        } withDependencies: {
            $0.shelfGroupStore.removeBooks = { _ in throw Failed() }
        }

        await store.send(.removeRequested) {
            $0.isShelfBusy = true
        }
        await store.receive(.removeFailed("本地数据库写入失败")) {
            $0.isShelfBusy = false
            $0.shelfNotice = "本地数据库写入失败"
        }
        XCTAssertTrue(store.state.isOnShelf)
        await store.finish()
    }

    func test详情映射回引擎书模型() {
        let detail = BookDetail(
            bookPath: "/49/49034/",
            title: "楚香君游戏",
            author: "某某某",
            coverUrl: "https://example.com/cover.jpg",
            intro: "简介",
            status: "连载中",
            category: "玄幻",
            tags: ["热血", "升级"],
            wordCount: "175万字",
            lastChapter: "第 131 章",
            lastUpdated: "2026-10-09"
        )

        let book = detail.book

        XCTAssertEqual(book.path, detail.bookPath)
        XCTAssertEqual(book.title, detail.title)
        XCTAssertEqual(book.author, detail.author)
        XCTAssertEqual(book.coverUrl, detail.coverUrl)
        XCTAssertEqual(book.status, detail.status)
        XCTAssertEqual(book.category, detail.category)
        XCTAssertEqual(book.tags, detail.tags)
        XCTAssertEqual(book.wordCount, detail.wordCount)
        XCTAssertEqual(book.lastChapter, detail.lastChapter)
        XCTAssertEqual(book.lastUpdated, detail.lastUpdated)
    }
}
