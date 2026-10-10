import ComposableArchitecture
@testable import NovelCore
import XCTest

/// 「到章尾无缝进下一章」的 reducer 侧用例。
///
/// 手势与动画本身（`DragGesture` / `withAnimation`）在纯 Swift 包里测不了，
/// 这里锁的是**状态迁移**：换章换得对不对、没有下一章时动不动、拿不到正文时安不安静、
/// 换章后有没有把新的下一章接上（链式）。
/// 判页那条边界规则（`PagePanTracking.turn`）与纯数学放在一起，见 `PagePanTrackingTests`。
///
/// 样本：每章都是「章名 + 10 个中文」，宽预算 10 ⇒ **3 页**
/// （`[0,6] [6,5] [10,4]`：章名 6 + 两个换行 2 + 1 个中文 2 = 满 10）。
@MainActor
final class ReaderChapterAdvanceTests: XCTestCase {
    // MARK: - 样本

    private static let first = ChapterItem(
        number: 1,
        name: "第一章",
        path: "/1/1.html",
        hasLocalText: true,
        isDownloaded: false
    )
    private static let second = ChapterItem(
        number: 2,
        name: "第二章",
        path: "/1/2.html",
        hasLocalText: true,
        isDownloaded: false
    )
    private static let third = ChapterItem(
        number: 3,
        name: "第三章",
        path: "/1/3.html",
        hasLocalText: true,
        isDownloaded: false
    )

    private static let firstText = "一二三四五六七八九十"
    private static let secondText = "甲乙丙丁戊己庚辛壬癸"
    private static let thirdText = "子丑寅卯辰巳午未申酉"

    // MARK: - 夹具

    private func makeStore(
        chapters: [ChapterItem],
        texts: [String: String],
        options: StoreOptions = StoreOptions()
    ) -> TestStore<ReaderFeature.State, ReaderFeature.Action> {
        TestStore(
            initialState: ReaderFeature.State(chapterPath: Self.first.path, chapters: chapters)
        ) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = { path in
                guard !options.failing.contains(path), let text = texts[path] else {
                    throw ChapterLoadError.unavailable
                }
                return text
            }
            // 进度与缓存都换成空桩：本文件只关心状态迁移，不关心落盘。
            $0.readingProgressStore.markRead = { _, _, _ in }
            $0.chapterCacheStore.cacheCurrentAndFollowing = options.cache ?? { _, _, _ in }
            $0.paginationService.paginate = options.paginate ?? paginateWithBudgetTen
        }
    }

    /// 公共前导：加载第 1 章（`loadChapterWithName` + `contentLoaded`）。
    ///
    /// 不含预加载结果：有没有下一章、拿不拿得到，各用例自己接。
    private func loadFirst(
        _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>
    ) async {
        await store.send(.loadChapterWithName(Self.first.path, Self.first.name)) {
            $0.chapterName = Self.first.name
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded(Self.firstText)) {
            $0.text = Self.firstText
            $0.isLoading = false
            $0.pages = expectedPages(chapter: Self.first, text: Self.firstText)
            $0.currentOffset = 0
        }
    }

    /// 把当前章推到最后一页（样本都是 3 页 ⇒ 两次 `nextPage`）。
    private func advanceToLastPage(
        _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>
    ) async {
        await store.send(.nextPage) { $0.currentOffset = 6 }
        await store.send(.nextPage) { $0.currentOffset = 10 }
    }

    // MARK: - 1. 章尾换章

    /// 最后一页 + 下一章已就绪 ⇒ `advanceChapter` 切到下一章：
    /// 路径 / 章名 / 正文 / 分页全换成下一章的，`currentOffset` 归零（契约③：位置存字符偏移）。
    func test章尾换章切到下一章并归零() async {
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText]
        )
        await loadFirst(store)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = secondPages
        }
        await advanceToLastPage(store)
        XCTAssertEqual(store.state.currentPageIndex, 2, "前置条件：已在第 1 章最后一页")
        XCTAssertFalse(store.state.nextPages.isEmpty, "前置条件：下一章第 1 页已就绪")

        await store.send(.advanceChapter) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = 0
            // 先清空再重算：旧值绝不能被当成新章的「下一章」。
            $0.nextText = ""
            $0.nextPages = []
        }
        await store.finish()

        XCTAssertEqual(store.state.chapterPath, Self.second.path)
        XCTAssertEqual(store.state.chapterName, Self.second.name)
        XCTAssertEqual(store.state.currentOffset, 0, "新章从头开始：存的是字符偏移，不是页码")
        XCTAssertEqual(store.state.pages, secondPages)
        XCTAssertEqual(store.state.currentPageIndex, 0)
        XCTAssertNil(store.state.nextChapter, "列表只有两章：第 2 章之后没有下一章")
    }

    // MARK: - 2. 没有下一章

    /// `chapters` 里找不到当前章（目录快照对不上）⇒ 同样按「没有下一章」处理。
    func test目录里找不到当前章时没有下一章() async {
        let store = makeStore(
            chapters: [Self.second, Self.third],
            texts: [Self.first.path: Self.firstText]
        )
        XCTAssertNil(store.state.nextChapter, "当前章不在列表里 ⇒ 不猜下一章")
        await loadFirst(store)
        await store.send(.advanceChapter)
        await store.finish()
        XCTAssertEqual(store.state.chapterPath, Self.first.path)
    }

    // MARK: - 2b. 相邻章派生（上一章 / 下一章）

    /// `previousChapter` 与 `nextChapter` 是同一份 `chapters` + `chapterPath` 的派生：
    /// 中间章两侧都有、**首章没有上一章**、**末章没有下一章**。
    /// 下栏上方的跳章按钮直接用这两个 `nil` 决定置灰，边界必须在这里锁死。
    func test相邻章派生在首末两端为空() {
        let chapters = [Self.first, Self.second, Self.third]

        let middleState = ReaderFeature.State(chapterPath: Self.second.path, chapters: chapters)
        XCTAssertEqual(middleState.previousChapter?.path, Self.first.path, "中间章两侧都有")
        XCTAssertEqual(middleState.nextChapter?.path, Self.third.path, "中间章两侧都有")

        let firstState = ReaderFeature.State(chapterPath: Self.first.path, chapters: chapters)
        XCTAssertNil(firstState.previousChapter, "首章没有上一章 ⇒ 「上一章」置灰")
        XCTAssertEqual(firstState.nextChapter?.path, Self.second.path)

        let lastState = ReaderFeature.State(chapterPath: Self.third.path, chapters: chapters)
        XCTAssertEqual(lastState.previousChapter?.path, Self.second.path)
        XCTAssertNil(lastState.nextChapter, "末章没有下一章 ⇒ 「下一章」置灰")
    }

    // MARK: - 3. 拿不到下一章时安静失败

    /// 下一章正文读失败 ⇒ 状态不变、不报错（`finish()` 同时证明没有冒出 `loadFailed`）。
    func test下一章加载失败时安静留空() async {
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText],
            options: StoreOptions(failing: [Self.second.path])
        )
        await loadFirst(store)
        await advanceToLastPage(store)

        await store.send(.advanceChapter)
        await store.finish()

        XCTAssertTrue(store.state.nextText.isEmpty)
        XCTAssertTrue(store.state.nextPages.isEmpty)
        XCTAssertNil(store.state.errorMessage)
        XCTAssertEqual(store.state.chapterPath, Self.first.path, "没就绪就不换章")
    }

    /// 下一章分页为空 ⇒ 同样安静留空：拿到了正文但没有可用的页，也不换章。
    func test下一章分页为空时安静留空() async {
        // 标记取成局部量：分页桩是 `@Sendable` 闭包，读不了 `@MainActor` 类的静态属性。
        let marker = Self.secondText
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText],
            options: StoreOptions(paginate: { text, config in
                // 只让下一章分不出页（它的渲染文本里带着这一章的正文）。
                text.contains(marker) ? [] : paginateWithBudgetTen(text, config)
            })
        )
        await loadFirst(store)
        // 正文拿到了、分页为空 ⇒ reducer 收到结果后仍不动状态（所以断言闭包为空）。
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText))
        await store.finish()

        XCTAssertTrue(store.state.nextText.isEmpty, "分页为空 ⇒ 正文也不留下（半份状态比没有更危险）")
        XCTAssertTrue(store.state.nextPages.isEmpty)
        XCTAssertNil(store.state.errorMessage)
    }

    // MARK: - 4. 链式：换章后重新预加载新的下一章

    /// 换到第 2 章后，reducer 自己把**新的**下一章（第 3 章）接上并预加载；到第 3 章收尾。
    func test换章后重新预加载新的下一章() async {
        let store = makeStore(
            chapters: [Self.first, Self.second, Self.third],
            texts: [
                Self.first.path: Self.firstText,
                Self.second.path: Self.secondText,
                Self.third.path: Self.thirdText,
            ]
        )
        await loadFirst(store)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = secondPages
        }

        await advanceToLastPage(store)
        await store.send(.advanceChapter) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = 0
            $0.nextText = ""
            $0.nextPages = []
        }
        // 链式：换章那一刻就重新声明了下一章（第 3 章）并重新预加载。
        let thirdPages = expectedPages(chapter: Self.third, text: Self.thirdText)
        await store.receive(.nextChapterLoaded(Self.third.path, Self.thirdText)) {
            $0.nextText = Self.thirdText
            $0.nextPages = thirdPages
        }
        await store.finish()
        XCTAssertEqual(store.state.chapterPath, Self.second.path)
        XCTAssertEqual(store.state.nextChapter?.path, Self.third.path)
        XCTAssertEqual(store.state.nextPages, thirdPages)

        // 再推进一章：第 3 章是最后一章 ⇒ 换章 action 不动，也不再有预加载结果。
        await advanceToLastPage(store)
        await store.send(.advanceChapter)
        await store.finish()
        XCTAssertEqual(store.state.chapterPath, Self.third.path)
        XCTAssertEqual(store.state.currentOffset, 10)
        XCTAssertNil(store.state.nextChapter)
        XCTAssertTrue(store.state.nextPages.isEmpty)
    }

    // MARK: - 5. 取消 / 重入：换章时旧的预加载结果必须作废

    /// 本章内容一换（含从目录手动跳章），旧的 `nextPages` 立刻作废 ——
    /// 否则 A 章的下一页会被当成 B 章的下一章，翻过去是错的正文。
    func test手动跳章时旧的下一章结果作废() async {
        let store = makeStore(
            chapters: [Self.first, Self.second, Self.third],
            texts: [
                Self.first.path: Self.firstText,
                Self.second.path: Self.secondText,
                Self.third.path: Self.thirdText,
            ]
        )
        await loadFirst(store)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = secondPages
        }

        // 从目录直接跳到第 3 章：第 2 章那份预加载结果必须同时被清掉。
        await store.send(.loadChapterWithName(Self.third.path, Self.third.name)) {
            $0.chapterPath = Self.third.path
            $0.chapterName = Self.third.name
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
            $0.nextText = ""
            $0.nextPages = []
        }
        await store.receive(.contentLoaded(Self.thirdText)) {
            $0.text = Self.thirdText
            $0.isLoading = false
            $0.pages = expectedPages(chapter: Self.third, text: Self.thirdText)
            $0.currentOffset = 0
        }
        await store.finish()
        XCTAssertEqual(store.state.chapterPath, Self.third.path)
        XCTAssertTrue(store.state.nextPages.isEmpty, "第 3 章是最后一章：没有下一章可预加载")
    }
}

// MARK: - 换章路径的自动缓存（放 extension：`type_body_length` 不计 extension）

/// 换章成功后必须**补一次**自动缓存：口径与 `contentLoaded` 完全一致
/// （新章路径 + 新章正文 + 当前 `precacheCount`）。
///
/// 少了这一步，「读过就缓存」这条闭环在换章路径上断掉 ——
/// 离线可读范围不再随阅读推进而扩大，越读越依赖联网。
extension ReaderChapterAdvanceTests {
    /// 换章成功后，缓存依赖被调用**一次**，且入参是「新章路径 + 新章正文 + 当前 precacheCount」。
    func test换章后按新章补一次自动缓存() async {
        let recorder = CacheCallRecorder()
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText],
            options: StoreOptions(cache: { path, text, count in
                await recorder.record(path: path, text: text, count: count)
            })
        )
        await loadFirst(store)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = secondPages
        }
        await advanceToLastPage(store)
        // 正常开章（`contentLoaded`）那一次已经记完；清空后只数换章这一次。
        await recorder.reset()
        let afterReset = await recorder.allRequests()
        XCTAssertTrue(afterReset.isEmpty, "前置条件：计数已清零")

        await store.send(.advanceChapter) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = 0
            $0.nextText = ""
            $0.nextPages = []
        }
        await store.finish()

        let requests = await recorder.allRequests()
        XCTAssertEqual(requests.count, 1, "换章只补一次缓存")
        XCTAssertEqual(requests.first?.path, Self.second.path, "缓存的是新章，不是刚离开的那一章")
        XCTAssertEqual(requests.first?.text, Self.secondText, "落盘的是新章正文")
        XCTAssertEqual(
            requests.first?.count,
            ReaderFeature.State(chapterPath: Self.first.path).precacheCount,
            "沿用当前 precacheCount（本用例没改过设置）"
        )
    }

    /// 边界：最后一章 ⇒ 不换章 ⇒ 缓存依赖**一次都不该被调用**
    /// （保证这一步只挂在真正的换章上，不是「每次点章尾都补」）。
    func test最后一章换章时缓存一次都不调用() async {
        let recorder = CacheCallRecorder()
        let store = makeStore(
            chapters: [Self.first],
            texts: [Self.first.path: Self.firstText],
            options: StoreOptions(cache: { path, text, count in
                await recorder.record(path: path, text: text, count: count)
            })
        )
        await loadFirst(store)
        await advanceToLastPage(store)
        await recorder.reset()

        await store.send(.advanceChapter)
        await store.finish()

        // 换章本身的既有口径不变：状态原地不动、不提示。
        XCTAssertEqual(store.state.chapterPath, Self.first.path)
        XCTAssertEqual(store.state.currentOffset, 10)
        XCTAssertNil(store.state.nextChapter)
        XCTAssertNil(store.state.errorMessage, "不提示：最后一章不产生任何错误文案")
        let requests = await recorder.allRequests()
        XCTAssertTrue(requests.isEmpty, "没换章就不该补缓存")
    }
}

// MARK: - 夹具（文件级纯函数，不占 `type_body_length`）

/// 夹具的可选旋钮：收成一个值类型，避免 `makeStore` 的参数个数越线
/// （`function_parameter_count` warning 5 / error 8，CI `--strict` 下 warning 即失败）。
private struct StoreOptions {
    var failing: Set<String> = []
    var paginate: (@Sendable (String, PaginationConfiguration) -> [PageRange])?
    var cache: (@Sendable (String, String, Int) async -> Void)?
}

/// 分页桩：宽预算 10 ⇒ 每页 5 个中文（`FakeMeasuring` 里中文宽 2、ASCII 宽 1）。
private let paginateWithBudgetTen: @Sendable (String, PaginationConfiguration) -> [PageRange] = { text, configuration in
    Paginator(measurer: FakeMeasuring(widthBudget: 10))
        .paginate(text: text, configuration: configuration)
}

/// 期望分页用的配置：与 `ReaderFeature.State` 的默认值同源（用例里没有任何改设置动作）。
private let defaultConfiguration = ReaderFeature.State(chapterPath: "/1/1.html").config

/// 期望分页的**独立**算法：这里自己把「章名 + 正文」拼出来（而不是问 reducer 要
/// `displayText`）—— 预加载若漏了章名，期望值就与它对不上，用例立刻红。
private func expectedPages(chapter: ChapterItem, text: String) -> [PageRange] {
    paginateWithBudgetTen(chapter.name + "\n\n" + text, defaultConfiguration)
}

/// 预加载失败用的错误：用例只关心「抛了」，不关心文案 —— 安静失败本就不该暴露任何文案。
private enum ChapterLoadError: Error {
    case unavailable
}

/// 记录自动缓存调用（spy）：与 `ReaderFeatureTests` 的 `CacheRecorder` 同一形态，
/// 额外支持 `reset()` —— 换章用例要先扣掉正常开章那一次，才能把「换章补缓存」单独数出来。
private actor CacheCallRecorder {
    struct Request: Sendable {
        let path: String
        let text: String
        let count: Int
    }

    private var records: [Request] = []

    func record(path: String, text: String, count: Int) {
        records.append(Request(path: path, text: text, count: count))
    }

    func reset() {
        records = []
    }

    func allRequests() -> [Request] {
        records
    }
}
