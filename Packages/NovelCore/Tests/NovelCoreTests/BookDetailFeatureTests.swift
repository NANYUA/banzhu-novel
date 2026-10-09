import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 详情页 reducer 测试。
///
/// ⚠️ 用例拆在多个 `@MainActor extension` 里：SwiftLint 的 `type_body_length`
/// 按**每个类型声明**算，全塞在一个 class body 里必然超限（`BookshelfFeatureTests` 同款拆法）。
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

    private static func makeChapter(number: Int, isDownloaded: Bool = false) -> ChapterItem {
        ChapterItem(
            number: number,
            name: "第 \(number) 章",
            path: "/1/\(number).html",
            hasLocalText: isDownloaded,
            isDownloaded: isDownloaded
        )
    }

    // MARK: - 详情加载

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
            $0.isLoadingChapters = true
        }
        // 没配置站点：host 读出来就是空串（入口隐藏）。
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(local)) {
            $0.detail = local
            $0.isLoading = false
            // 🔴 本地命中记录 == 已在书架：详情页据此显示「移出书架」。
            $0.isOnShelf = true
        }
        await store.receive(.chaptersLoaded([])) {
            $0.isLoadingChapters = false
        }
        await store.finish()
    }

    func test本地无记录时保留搜索回退值且不在书架() async {
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        await store.receive(.chaptersLoaded([])) {
            $0.isLoadingChapters = false
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
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loadFailed("加载失败")) {
            $0.isLoading = false
            $0.errorMessage = "加载失败"
        }
        await store.receive(.chaptersLoaded([])) {
            $0.isLoadingChapters = false
        }
        XCTAssertEqual(store.state.detail, Self.fallback)
        XCTAssertFalse(store.state.isOnShelf)
        await store.finish()
    }
}

// MARK: - 详情映射 / 阅读位置

@MainActor extension BookDetailFeatureTests {
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

    func test详情保留上次阅读章节且不影响回引擎书模型() {
        let detail = BookDetail(
            bookPath: Self.bookPath,
            title: "本地书名",
            lastReadChapterPath: "/1/7.html",
            lastReadChapterName: "第七章"
        )

        XCTAssertEqual(detail.lastReadChapterPath, "/1/7.html")
        XCTAssertEqual(detail.lastReadChapterName, "第七章")
        // `Book` 没有阅读位置字段：映射回引擎模型时不受影响。
        XCTAssertEqual(detail.book.path, Self.bookPath)
        // 搜索回退出来的快照没有阅读位置。
        XCTAssertNil(Self.fallback.lastReadChapterPath)
    }
}

// MARK: - host / 原网站入口（U1-4）

@MainActor extension BookDetailFeatureTests {
    func test加载时顺带读站点host与目录() async {
        let chapters = [
            Self.makeChapter(number: 1),
            Self.makeChapter(number: 2, isDownloaded: true),
        ]
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.siteStore.load = { SiteSettings(hosts: [SiteEntry(value: "demo.example")]) }
            $0.chapterListLoader.load = { bookPath in
                XCTAssertEqual(bookPath, Self.bookPath)
                return chapters
            }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded("demo.example")) {
            $0.host = "demo.example"
        }
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        await store.receive(.chaptersLoaded(chapters)) {
            $0.chapters = chapters
            $0.isLoadingChapters = false
        }
        // 原网站 URL 现场拼：无协议写法会补上 https。
        XCTAssertEqual(store.state.sourceURL?.absoluteString, "https://demo.example/1/")
        await store.finish()
    }

    func test未配置host时不给原网站入口() {
        var state = BookDetailFeature.State(fallback: Self.fallback)
        XCTAssertNil(state.sourceURL)

        state.host = "   "
        XCTAssertNil(state.sourceURL)
    }

    func test原网站URL由当前配置的host现场拼出() {
        var state = BookDetailFeature.State(fallback: Self.fallback)
        state.host = "demo.example"
        XCTAssertEqual(state.sourceURL?.absoluteString, "https://demo.example/1/")

        // 换一个 host 就必须换一个 URL —— 域名只能来自用户配置，不能写死。
        state.host = "https://another.example"
        XCTAssertEqual(state.sourceURL?.absoluteString, "https://another.example/1/")
    }
}

// MARK: - 目录（U1-6）

@MainActor extension BookDetailFeatureTests {
    func test目录加载失败只记目录错误() async {
        struct Failed: LocalizedError {
            var errorDescription: String? {
                "目录加载失败"
            }
        }
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.chapterListLoader.load = { _ in throw Failed() }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        await store.receive(.chaptersFailed("目录加载失败")) {
            $0.isLoadingChapters = false
            $0.chapterErrorMessage = "目录加载失败"
        }
        // 目录失败不该污染详情本身。
        XCTAssertNil(store.state.errorMessage)
        await store.finish()
    }

    func test重试目录不再重新读详情() async {
        struct Unexpected: Error {}
        let chapters = [Self.makeChapter(number: 1)]
        var initial = BookDetailFeature.State(fallback: Self.fallback)
        initial.chapterErrorMessage = "目录加载失败"
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        } withDependencies: {
            // 详情加载器只要被调用就抛错：重试目录不该走详情那条路径。
            $0.bookDetailLoader.load = { _ in throw Unexpected() }
            $0.chapterListLoader.load = { _ in chapters }
        }

        await store.send(.reloadChapters) {
            $0.isLoadingChapters = true
            $0.chapterErrorMessage = nil
        }
        await store.receive(.chaptersLoaded(chapters)) {
            $0.chapters = chapters
            $0.isLoadingChapters = false
        }
        await store.finish()
    }

    func test目录默认只渲染前若干条展开后可看全部() async {
        let chapters = (1 ... 20).map { Self.makeChapter(number: $0) }
        var initial = BookDetailFeature.State(fallback: Self.fallback)
        initial.chapters = chapters
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        }

        XCTAssertEqual(
            store.state.visibleChapters.count,
            BookDetailFeature.State.chapterPreviewLimit
        )
        XCTAssertTrue(store.state.hasHiddenChapters)

        await store.send(.toggleAllChapters) {
            $0.isShowingAllChapters = true
        }
        XCTAssertEqual(store.state.visibleChapters.count, chapters.count)
        XCTAssertFalse(store.state.hasHiddenChapters)
        await store.finish()
    }

    func test已下载章节计数按source标记统计() {
        var state = BookDetailFeature.State(fallback: Self.fallback)
        state.chapters = [
            Self.makeChapter(number: 1, isDownloaded: true),
            Self.makeChapter(number: 2),
            Self.makeChapter(number: 3, isDownloaded: true),
        ]

        XCTAssertEqual(state.downloadedChapterCount, 2)
        XCTAssertEqual(state.downloadableChapterCount, 1)
    }
}

// MARK: - 继续阅读

@MainActor extension BookDetailFeatureTests {
    func test继续阅读命中上次读到的章节() {
        var state = BookDetailFeature.State(fallback: BookDetail(
            bookPath: Self.bookPath,
            title: "本地书名",
            lastReadChapterPath: "/1/7.html",
            lastReadChapterName: "第七章"
        ))
        state.chapters = [Self.makeChapter(number: 1), Self.makeChapter(number: 7)]

        XCTAssertEqual(state.continueChapter?.number, 7)
    }

    func test上次阅读章节已不在目录时退回开始阅读() {
        var state = BookDetailFeature.State(fallback: BookDetail(
            bookPath: Self.bookPath,
            title: "本地书名",
            lastReadChapterPath: "/1/99.html"
        ))
        state.chapters = [Self.makeChapter(number: 1)]

        XCTAssertNil(state.continueChapter)
    }
}

// MARK: - 加入 / 移出书架

@MainActor extension BookDetailFeatureTests {
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
}
