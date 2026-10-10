import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 「未上架书的远端兜底**失败**」这条链路的回归测试（U9-2 收口）。
///
/// 上一版（`3660b6b`）在 `onAppear` 串行链尾部加了远端兜底，但用的是 `try?`：
/// 兜底一失败就**什么都不发** —— 页面保持搜索列表的回退字段（列表页没有简介）与空目录，
/// 既不报错也不给重试。真机上「仍然没有简介、没有章节、进不了阅读」与
/// 「兜底压根没被调用」在界面上完全一样，无法区分。
///
/// 本文件守三件事：
/// 1. 兜底失败 → `previewErrorMessage` 带**真实原因**出现，且已上架的书不受影响；
/// 2. 失败后「重试」→ **重新**兜底，成功后首屏被填满、失败提示消失；
/// 3. 兜底成功 → **View 实际读的每一个字段**都被填（逐项断言，见每条断言后的 `文件:行`）。
///
/// 🔴 脱敏：本文件只出现 `example.com` 与 `/49/49034/` 这类既有占位。
@MainActor
final class BookDetailPreviewFailureTests: XCTestCase {
    private static let bookPath = "/49/49034/"
    private static let fallback = BookDetail(bookPath: bookPath, title: "搜索结果")

    /// 站点**没配置**时的完整失败文案 = 「没配站点」那句 + 真实原因。
    private static var noHostMessage: String {
        "还没有配置站点地址，无法联网读取这本书的简介与目录。\(previewFailureReason)"
    }

    /// 兜底回来的详情。字段取全，便于逐项核对 View 依赖。
    private static let remoteDetail = BookDetail(
        bookPath: bookPath,
        title: "远端书名",
        author: "远端作者",
        coverUrl: "https://example.com/cover.jpg",
        intro: "远端简介",
        status: "连载中",
        category: "玄幻",
        tags: ["热血"],
        wordCount: "10万字",
        lastChapter: "第十二章",
        lastUpdated: "2026-10-09"
    )

    private static func makeChapter(number: Int) -> ChapterItem {
        ChapterItem(
            number: number,
            name: "第 \(number) 章",
            path: "\(bookPath)\(number).html",
            hasLocalText: false,
            isDownloaded: false
        )
    }

    /// 「未上架 + 兜底成功」的标准桩：省掉每条用例重复的依赖注入。
    private func makeStore(
        chapters: [ChapterItem]
    ) -> TestStore<BookDetailFeature.State, BookDetailFeature.Action> {
        TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            // 搜索路径：本地既没有这本书的记录，目录快照也是空的。
            $0.bookDetailLoader.load = { _ in nil }
            $0.chapterListLoader.load = { _ in [] }
            $0.bookDetailLoader.preview = { _ in
                BookPreview(detail: Self.remoteDetail, chapters: chapters)
            }
        }
    }

    /// 把「首屏 → 兜底成功」这一串动作走完（多条用例共用，动作序列只写一处）。
    private func runToPreviewLoaded(
        _ store: TestStore<BookDetailFeature.State, BookDetailFeature.Action>,
        chapters: [ChapterItem]
    ) async {
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
        await store.receive(.previewLoaded(detail: Self.remoteDetail, chapters: chapters)) {
            $0.detail = Self.remoteDetail
            $0.chapters = chapters
        }
    }

    // MARK: - ① 兜底失败必须可见（带原因）

    func test兜底失败时给出真实原因而不是安静空白() async {
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in nil }
            $0.chapterListLoader.load = { _ in [] }
            $0.bookDetailLoader.preview = { _ in throw PreviewFailed() }
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
        await store.receive(.previewFailed(Self.noHostMessage)) {
            $0.previewErrorMessage = Self.noHostMessage
        }

        let message = store.state.previewErrorMessage
        // 失败原因必须**具体**：真实错误被带出来（上一版这里什么都没有）。
        XCTAssertTrue(message?.contains(previewFailureReason) == true, "真实错误未被带出：\(message ?? "nil")")
        // 站点没配置时还要点明前提，否则用户只会看到一条「服务器返回错误」。
        XCTAssertTrue(message?.contains("还没有配置站点地址") == true, "未点明没配站点：\(message ?? "nil")")
        XCTAssertFalse(store.state.isPreviewLoading)
        // 首屏仍是搜索列表的回退字段（列表页没有简介）与空目录 —— 这正是必须报错的原因。
        XCTAssertEqual(store.state.detail, Self.fallback)
        XCTAssertTrue(store.state.chapters.isEmpty)
        // 兜底失败不改「未上架」这个判定：按钮仍是「加入书架」。
        XCTAssertFalse(store.state.isOnShelf)
        await store.finish()
    }

    func test已配置站点时失败文案就是真实原因() async {
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in nil }
            $0.chapterListLoader.load = { _ in [] }
            $0.bookDetailLoader.preview = { _ in throw PreviewFailed() }
            $0.siteStore.load = {
                SiteSettings(hosts: [SiteEntry(value: "https://example.com")])
            }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        // host 非空 ⇒ `hostLoaded` 一定会改写 `state.host`，尾随闭包不能省：
        // 省掉就是断言「状态没变」，TestStore 会判 `State was not expected to change`。
        await store.receive(.hostLoaded("https://example.com")) {
            $0.host = "https://example.com"
        }
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        await store.receive(.chaptersLoaded([])) {
            $0.isLoadingChapters = false
        }
        // 有站点时不该出现「没配站点」那句：文案就是错误本身，不多不少。
        await store.receive(.previewFailed(previewFailureReason)) {
            $0.previewErrorMessage = previewFailureReason
        }
        XCTAssertEqual(store.state.previewErrorMessage, previewFailureReason)
        await store.finish()
    }

    /// 已上架的书不受兜底失败影响：兜底只服务「未上架且本地没有数据」的首屏。
    ///
    /// 现实触发点是「兜底还在飞的时候用户把这本书加进了书架」（`isOnShelf` 翻真）——
    /// 那时这条网络失败与他已经修好的页面无关，不该挂在他面前。
    func test已上架的书不受兜底失败影响() async {
        var initial = BookDetailFeature.State(fallback: Self.fallback)
        initial.detail = Self.remoteDetail
        initial.chapters = [Self.makeChapter(number: 1)]
        initial.isOnShelf = true
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        }

        // 状态不变 ⇒ **不传**尾随闭包（传了就等于断言「状态变了」）。
        await store.send(.previewFailed(previewFailureReason))
        XCTAssertNil(store.state.previewErrorMessage)
        XCTAssertEqual(store.state.detail, Self.remoteDetail)
        XCTAssertEqual(store.state.chapters.count, 1)
        XCTAssertTrue(store.state.isOnShelf)
        await store.finish()
    }
}

// MARK: - ② 重试 / ③ 兜底成功后 View 依赖的字段

// 与主 class 拆开：SwiftLint 的 `type_body_length` 按每个类型声明算。

@MainActor extension BookDetailPreviewFailureTests {
    /// 兜底失败后点「重试」：**重新**发起兜底（不是重读本地），成功后首屏被填满、提示消失。
    func test兜底失败后重试成功填满首屏() async {
        let chapters = [Self.makeChapter(number: 1), Self.makeChapter(number: 2)]
        let attempts = AttemptCounter()
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in nil }
            $0.chapterListLoader.load = { _ in [] }
            $0.bookDetailLoader.preview = { _ in
                // 首屏那次失败、重试那次成功：只有「重试真的重新兜底了」才能走到成功。
                if await attempts.next() == 1 {
                    throw PreviewFailed()
                }
                return BookPreview(detail: Self.remoteDetail, chapters: chapters)
            }
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
        await store.receive(.previewFailed(Self.noHostMessage)) {
            $0.previewErrorMessage = Self.noHostMessage
        }
        let firstAttempts = await attempts.count
        XCTAssertEqual(firstAttempts, 1, "首屏只该兜底一次")

        await store.send(.reloadPreview) {
            $0.isPreviewLoading = true
        }
        await store.receive(.previewLoaded(detail: Self.remoteDetail, chapters: chapters)) {
            $0.detail = Self.remoteDetail
            $0.chapters = chapters
            $0.isPreviewLoading = false
            $0.previewErrorMessage = nil
        }

        let secondAttempts = await attempts.count
        XCTAssertEqual(secondAttempts, 2, "重试必须重新发起兜底")
        XCTAssertNil(store.state.previewErrorMessage, "成功后失败提示必须消失")
        XCTAssertFalse(store.state.isPreviewLoading)
        XCTAssertEqual(store.state.chapters.count, 2)
        await store.finish()
    }

    /// 兜底成功：**View 实际读的每一个字段**都要就位（逐项对着 `BookDetailView` 核）。
    func test兜底成功后View依赖的字段全部就位() async {
        let chapters = (1 ... 3).map { Self.makeChapter(number: $0) }
        let store = makeStore(chapters: chapters)
        await runToPreviewLoaded(store, chapters: chapters)

        // header / infoSection（BookDetailView.swift:138 / :181）
        XCTAssertEqual(store.state.detail.title, "远端书名")
        XCTAssertEqual(store.state.detail.author, "远端作者")
        XCTAssertEqual(store.state.detail.coverUrl, "https://example.com/cover.jpg")
        XCTAssertEqual(store.state.detail.status, "连载中")
        XCTAssertEqual(store.state.detail.category, "玄幻")
        XCTAssertEqual(store.state.detail.tags, ["热血"])
        XCTAssertEqual(store.state.detail.wordCount, "10万字")
        XCTAssertEqual(store.state.detail.lastChapter, "第十二章")
        XCTAssertEqual(store.state.detail.lastUpdated, "2026-10-09")
        // introSection 读 `detail.intro`（BookDetailView.swift:83 / :308）—— 真机缺陷里最先缺的就是它。
        XCTAssertEqual(store.state.detail.intro, "远端简介")
        // primaryActions 依赖 `chapters.first`（BookDetailView.swift:416）—— 没有它阅读按钮不渲染。
        XCTAssertEqual(store.state.chapters.first?.path, "/49/49034/1.html")
        // directorySection 读 `visibleChapters` 与 `chapters.count`（BookDetailView.swift:469-478）
        XCTAssertEqual(store.state.visibleChapters.count, 3)
        XCTAssertEqual(store.state.visibleChapters.first?.name, "第 1 章")
        // 目录 header 的计数口径（ChapterListView.swift:86）
        XCTAssertEqual(store.state.downloadedChapterCount, 0)
        XCTAssertEqual(store.state.downloadableChapterCount, 3)
        XCTAssertFalse(store.state.hasHiddenChapters)
        // 「继续阅读」的判据：兜底数据没有本地阅读位置 ⇒ 走「开始阅读」（BookDetailView.swift:399）
        XCTAssertNil(store.state.continueChapter)
        // 兜底是现场从网络拿的，不代表这本书进了书架（BookDetailView.swift:239）
        XCTAssertFalse(store.state.isOnShelf)
        XCTAssertNil(store.state.previewErrorMessage)
        XCTAssertFalse(store.state.isPreviewLoading)
        await store.finish()
    }

    /// 兜底成功 + 本地目录读取失败：过期的「目录加载失败」必须被清掉（既有行为，一并钉住）。
    func test兜底成功后清掉过期的目录失败提示() async {
        let chapters = [Self.makeChapter(number: 1)]
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in nil }
            $0.chapterListLoader.load = { _ in throw PreviewFailed() }
            $0.bookDetailLoader.preview = { _ in
                BookPreview(detail: Self.remoteDetail, chapters: chapters)
            }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        await store.receive(.chaptersFailed(previewFailureReason)) {
            $0.isLoadingChapters = false
            $0.chapterErrorMessage = previewFailureReason
        }
        await store.receive(.previewLoaded(detail: Self.remoteDetail, chapters: chapters)) {
            $0.detail = Self.remoteDetail
            $0.chapters = chapters
            $0.chapterErrorMessage = nil
        }
        XCTAssertNil(store.state.chapterErrorMessage)
        XCTAssertEqual(store.state.chapters, chapters)
        await store.finish()
    }
}

// MARK: - 测试替身

/// 兜底失败的真实原因。既是 `PreviewFailed` 的文案，也是断言里的期望值 —— 只写一处。
private let previewFailureReason = "网络连接中断"

/// 兜底失败用的错误：它的文案必须被带到界面上（不再被 `try?` 吞掉）。
private struct PreviewFailed: LocalizedError {
    var errorDescription: String? {
        previewFailureReason
    }
}

/// 兜底被调用的次数。
///
/// 用 `actor` 而不是裸 `var`：`preview` 是 `@Sendable` 闭包，跨并发域计数不能共享可变状态。
private actor AttemptCounter {
    private var value = 0

    var count: Int {
        value
    }

    func next() -> Int {
        value += 1
        return value
    }
}
