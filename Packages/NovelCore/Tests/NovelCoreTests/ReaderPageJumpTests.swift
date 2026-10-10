import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 「拖动进度条跳到本章第 N 页」的 reducer 侧用例。
///
/// 视图侧（`Slider` 的跟手本地值、命中区、无障碍）在纯 Swift 包里测不了，
/// 这里锁的是**状态迁移与落盘口径**：跳到哪一页、越界动不动、拖动中落不落盘、
/// 抬手落盘的那一条 offset 是什么。
///
/// 单独一个文件（而不是塞进 `ReaderFeatureTests`）：那个文件已 577 行、贴着
/// SwiftLint `file_length` 600 的 warning 线（CI `--strict` 下 warning 即失败）。
/// 夹具刻意**自成一份**且全部 `private`：跨文件复用就得把另一份的 `private` 夹具
/// 放开成 internal，改动面反而更大（既有先例见 `ReaderChapterRetreatTests` 的文件头）。
///
/// 样本：`"第一章" + 15 个中文`、宽预算 10 ⇒ **4 页**（页首偏移一律从
/// `pageJumpExpectedPages(chapterName:text:)` 推，**不写死数字**）。
@MainActor
final class ReaderPageJumpTests: XCTestCase {
    // MARK: - 跳页

    /// 🔴 数据契约③：`.goToPage(3)` 落到**第 3 页页首的字符偏移**（不是页码），
    /// 且 `currentPageIndex` 随之变成 3。
    func test跳到指定页落到该页页首字符偏移() async {
        let store = pageJumpMakeStore { _, _, _ in }
        let pages = await pageJumpLoad(store)
        // 用 `guard` 而不是 `XCTAssert`：断言失败后仍会往下走，`pages[3]` 越界会把整轮测试崩掉。
        guard pages.indices.contains(3) else {
            XCTFail("前置条件：样本要分出 4 页以上，跳到第 3 页才有意义")
            return
        }
        XCTAssertNotEqual(pages[3].location, 0, "前置条件：第 3 页页首不是 0，契约断言才有意义")

        await store.send(.goToPage(3)) {
            $0.currentOffset = pages[3].location
        }
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, pages[3].location, "必须落到该页页首的字符偏移")
        XCTAssertEqual(store.state.currentPageIndex, 3)
    }

    /// 越界（负数 / 等于页数）⇒ **零状态变化**。
    ///
    /// `store.send(action)` 不带断言闭包就是「期望状态不变」，改了状态 TestStore 会直接红。
    func test越界跳页零状态变化() async {
        let store = pageJumpMakeStore { _, _, _ in }
        let pages = await pageJumpLoad(store)

        await store.send(.goToPage(-1))
        await store.send(.goToPage(pages.count))
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 0)
        XCTAssertEqual(store.state.currentPageIndex, 0)
    }

    /// 同一页重复跳（拖动中同一个整数会被反复取整到）⇒ 状态零变化。
    func test重复跳同一页不动状态() async {
        let store = pageJumpMakeStore { _, _, _ in }
        let pages = await pageJumpLoad(store)
        guard pages.indices.contains(2) else {
            XCTFail("前置条件：样本要分出 3 页以上")
            return
        }

        await store.send(.goToPage(2)) { $0.currentOffset = pages[2].location }
        await store.send(.goToPage(2))
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, pages[2].location)
        XCTAssertEqual(store.state.currentPageIndex, 2)
    }

    /// `applyPageJump` 的返回值语义（reducer 的 `.goToPage` 靠它决定「真的跳了吗」）：
    /// 真的跳了 = `true`；越界 / 原地不动 = `false`。
    func testapplyPageJump返回值() {
        var state = ReaderFeature.State(chapterPath: pageJumpPath)
        state.pages = [
            PageRange(location: 0, length: 5),
            PageRange(location: 5, length: 5),
        ]

        let jumped = applyPageJump(&state, to: 1)
        XCTAssertTrue(jumped, "从第 0 页跳到第 1 页 ⇒ true")
        XCTAssertEqual(state.currentOffset, state.pages[1].location, "落到页首字符偏移")

        let jumpedAgain = applyPageJump(&state, to: 1)
        XCTAssertFalse(jumpedAgain, "已经在页首 ⇒ 状态没变，false")
        let pastEnd = applyPageJump(&state, to: 2)
        XCTAssertFalse(pastEnd, "越界（等于页数）⇒ false")
        let negative = applyPageJump(&state, to: -1)
        XCTAssertFalse(negative, "越界（负数）⇒ false")
        XCTAssertEqual(state.currentOffset, state.pages[1].location, "两次越界都不许动状态")
    }

    // MARK: - 落盘口径

    /// 🔴 `.goToPage` **不落盘**：拖动中它会被调用上百次，一次拖动不能变成上百次 SwiftData 写。
    func test跳页不落盘() async {
        let recorder = PageJumpProgressRecorder()
        let store = pageJumpMakeStore { path, offset, date in
            await recorder.record(path: path, offset: offset, date: date)
        }
        let pages = await pageJumpLoad(store)
        // 开章本身会写一条（`contentLoaded` 的 markRead），先清掉才数得清跳页那几次。
        await recorder.reset()

        // 跳过第 0 页：store 本来就在第 0 页页首，跳过去是**有意**的空操作（见边界用例）。
        for index in pages.indices.dropFirst() {
            await store.send(.goToPage(index)) { $0.currentOffset = pages[index].location }
        }
        await store.finish()

        let records = await recorder.allRecords()
        XCTAssertTrue(records.isEmpty, "`.goToPage` 不许落盘，实际写了 \(records.count) 条")
    }

    /// `.pageJumpCommitted` 落盘**一次**，且 `offset` 是**当前页页首的 `progressOffset`**
    /// （已扣掉章名前缀）—— 不是 0、也不是 `currentOffset`。
    func test抬手落盘一次且为页首进度偏移() async {
        let recorder = PageJumpProgressRecorder()
        let store = pageJumpMakeStore { path, offset, date in
            await recorder.record(path: path, offset: offset, date: date)
        }
        let pages = await pageJumpLoad(store)
        await recorder.reset()

        guard let target = pages.indices.last else {
            XCTFail("前置条件：样本必须分页成功（至少 1 页）")
            return
        }
        await store.send(.goToPage(target)) { $0.currentOffset = pages[target].location }
        // 抬手：不落盘以外的状态变化都没有 ⇒ 不带断言闭包。
        await store.send(.pageJumpCommitted)
        await store.finish()

        let prefix = store.state.titlePrefixLength
        XCTAssertGreaterThan(prefix, 0, "前置条件：带章名加载 ⇒ 前缀长度 > 0，下面两条断言才有意义")
        let records = await recorder.allRecords()
        XCTAssertEqual(records.count, 1, "抬手只落盘一次")
        XCTAssertEqual(records.first?.path, pageJumpPath)
        // 期望值从**被测系统的分页输出**推出（页首 location − 章名前缀），不写死数字。
        XCTAssertEqual(records.first?.offset, pages[target].location - prefix)
        XCTAssertNotEqual(records.first?.offset, 0, "落盘的必须是当前页页首，不是 0")
        XCTAssertNotEqual(
            records.first?.offset,
            store.state.currentOffset,
            "落盘口径是 progressOffset（已扣章名前缀），不是 currentOffset"
        )
    }

    // MARK: - 边界（视图侧降级的依据）

    /// `pages` 为空（正文还没排完）与单页章：`.goToPage` 一律不动状态。
    ///
    /// 这两条同时是**视图侧降级**的依据：`pageCount <= 1` 时不渲染进度条
    /// （单页章没有「拖到第几页」这回事，见 `ReaderPageScrubber` 的类型注释）。
    func test空正文与单页章的跳页边界() async {
        // ① 正文还没排完：`ReaderFeature.State` 的 `pages` 默认为空 ⇒ `currentPageIndex` 是 -1。
        let emptyStore = pageJumpMakeStore { _, _, _ in }
        XCTAssertTrue(emptyStore.state.pages.isEmpty, "前置条件：新 store 的 pages 为空")
        XCTAssertEqual(emptyStore.state.currentPageIndex, -1, "前置条件：空正文没有当前页")

        await emptyStore.send(.goToPage(0))
        await emptyStore.finish()
        XCTAssertEqual(emptyStore.state.currentOffset, 0)

        // ② 单页章：只有第 0 页，且已经在页首 ⇒ 跳第 0 页与跳第 1 页都不动状态。
        let singleStore = pageJumpMakeStore(text: pageJumpSinglePageText) { _, _, _ in }
        let singlePages = await pageJumpLoad(singleStore, text: pageJumpSinglePageText)
        XCTAssertEqual(singlePages.count, 1, "前置条件：该样本要正好排成 1 页")

        await singleStore.send(.goToPage(0))
        await singleStore.send(.goToPage(1))
        await singleStore.finish()
        XCTAssertEqual(singleStore.state.currentOffset, 0)
        XCTAssertEqual(singleStore.state.currentPageIndex, 0)
    }
}

// MARK: - 样本与夹具（文件级，不占 `type_body_length`）

private let pageJumpPath = "/1/1.html"
private let pageJumpChapterName = "第一章"
/// 15 个中文：配 `"第一章\n\n"` 与宽预算 10 ⇒ 4 页（6 / 5 / 5 / 4 个字符）。
private let pageJumpSampleText = "一二三四五六七八九十甲乙丙丁戊"
/// 1 个中文：配 `"第一章\n\n"` 与宽预算 10 ⇒ 正好 1 页（首页只放得下 1 个中文）。
private let pageJumpSinglePageText = "一"
/// 宽预算 10（与 `FakeMeasuring` 的中文宽 2 对应 ⇒ 纯正文页每页 5 个中文）。
private let pageJumpWidthBudget = 10

/// 期望分页的**独立**算法：这里自己把「章名 + 正文」拼出来（而不是问 reducer 要
/// `displayText`）—— 拼接规则若分叉，期望值就与实现对不上，用例立刻红。
private func pageJumpExpectedPages(chapterName: String, text: String) -> [PageRange] {
    Paginator(measurer: FakeMeasuring(widthBudget: pageJumpWidthBudget))
        .paginate(
            text: chapterName + "\n\n" + text,
            configuration: ReaderFeature.State(chapterPath: pageJumpPath).config
        )
}

/// 建 store：只换掉 loader / 进度落盘 / 缓存 / 分页四个依赖，其余走真实默认值。
///
/// 分页桩与 `pageJumpExpectedPages` 同一套（`FakeMeasuring` + 同一个预算），
/// 所以「期望值」与「被测系统的输出」同源但**独立计算**。
@MainActor
private func pageJumpMakeStore(
    text: String = pageJumpSampleText,
    progress: @escaping @Sendable (String, Int, Date) async throws -> Void
) -> TestStore<ReaderFeature.State, ReaderFeature.Action> {
    TestStore(initialState: ReaderFeature.State(chapterPath: pageJumpPath)) {
        ReaderFeature()
    } withDependencies: {
        $0.readerLoader.load = { _ in text }
        $0.readingProgressStore.markRead = progress
        // 本文件只数进度落盘的次数与口径：缓存换成空桩。
        $0.chapterCacheStore.cacheCurrentAndFollowing = { _, _, _ in }
        $0.paginationService.paginate = { text, configuration in
            Paginator(measurer: FakeMeasuring(widthBudget: pageJumpWidthBudget))
                .paginate(text: text, configuration: configuration)
        }
    }
}

/// 公共前导：带章名加载样本章（`loadChapterWithName` + `contentLoaded`），返回期望分页。
@MainActor
private func pageJumpLoad(
    _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>,
    text: String = pageJumpSampleText
) async -> [PageRange] {
    let pages = pageJumpExpectedPages(chapterName: pageJumpChapterName, text: text)
    await store.send(.loadChapterWithName(pageJumpPath, pageJumpChapterName)) {
        $0.chapterName = pageJumpChapterName
        $0.isLoading = true
        $0.text = ""
        $0.pages = []
        $0.currentOffset = 0
    }
    await store.receive(.contentLoaded(text)) {
        $0.text = text
        $0.isLoading = false
        $0.pages = pages
        $0.currentOffset = 0
    }
    return pages
}

/// 记录阅读进度调用（spy）：跳页用例要先扣掉开章那一条，才能把「跳页 / 抬手」数清楚。
private actor PageJumpProgressRecorder {
    struct Call: Sendable {
        let path: String
        let offset: Int
        let date: Date
    }

    private var calls: [Call] = []

    func record(path: String, offset: Int, date: Date) {
        calls.append(Call(path: path, offset: offset, date: date))
    }

    func reset() {
        calls = []
    }

    func allRecords() -> [Call] {
        calls
    }
}
