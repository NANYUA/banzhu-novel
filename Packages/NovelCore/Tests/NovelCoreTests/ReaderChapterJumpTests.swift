import ComposableArchitecture
@testable import NovelCore
import XCTest

/// 「跳章条的上一章 / 下一章」的 reducer 侧用例。
///
/// 背景（owner 真机反馈）：「现在阅读界面的预缓存不起效果，我直接点击下一章还是需要加载」——
/// 相邻章其实早就预加载好了，只是按钮走的是 `loadChapterWithName`（**整章重新加载** ⇒ 转圈）。
/// 现在按钮发 `.jumpToAdjacentChapter(目标章)`，由 `jumpToAdjacentChapter` 决定走哪条路：
/// **已就绪的相邻章 ⇒ 直接换章（全程无 loading）**；未就绪 ⇒ 回退完整加载（与改动前一致）。
/// 两条路**落同一页**（新章章首）—— 否则「缓存好没好」会让同一个按钮跳到不同的页。
///
/// 单独一个文件（而不是塞进 `ReaderChapterAdvanceTests`）：那个文件已经 531 行、
/// 贴着 SwiftLint `file_length` 600 的 warning 线（CI `--strict` 下 warning 即失败），
/// 装不下这一组。夹具刻意**自成一份**（与 `ReaderChapterRetreatTests` 同一做法）：
/// 跨文件复用就得把另一份的 `private` 夹具全部放开成 internal，改动面反而更大。
///
/// 样本与那两个文件同口径：每章「章名 + 10 个中文」、宽预算 10 ⇒ 3 页，
/// 页首偏移 **0 / 6 / 11**（一律从 `expectedPages(chapter:text:)` 推，不写死数字）。
@MainActor
final class ReaderChapterJumpTests: XCTestCase {
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
            // 进度与缓存都换成空桩：本文件只关心「按钮换章走哪条路」，不关心落盘。
            $0.readingProgressStore.markRead = { _, _, _ in }
            $0.chapterCacheStore.cacheCurrentAndFollowing = options.cache ?? { _, _, _ in }
            $0.paginationService.paginate = options.paginate ?? paginateWithBudgetTen
        }
    }

    /// 公共前导：走正常开章路径加载第 1 章（`loadChapterWithName` + `contentLoaded`）。
    ///
    /// **不含**预加载结果：按钮那一侧就绪与否，各用例自己接。
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

    /// 公共前导：加载第 1 章 → 收下「下一章（第 2 章）」的预加载结果 ⇒ 按钮那一侧**就绪**。
    ///
    /// 返回第 2 章的分页（调用方后面断言要用），省得每处再算一遍。
    private func loadFirstAndPreloadSecond(
        _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>
    ) async -> [PageRange] {
        await loadFirst(store)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = secondPages
        }
        return secondPages
    }

    /// 公共前导（「上一章」用例用）：跳到第 2 章，并收下它的上一章（第 1 章）的预加载结果。
    ///
    /// 抽成夹具是为了压 `function_body_length`：这一串动作原样写进用例里会顶到 50 行。
    private func jumpToSecondAndPreloadFirst(
        _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>,
        secondPages: [PageRange]
    ) async -> [PageRange] {
        await store.send(.jumpToAdjacentChapter(Self.second)) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = 0
            $0.nextText = ""
            $0.nextPages = []
        }
        let firstPages = expectedPages(chapter: Self.first, text: Self.firstText)
        await store.receive(.previousChapterLoaded(Self.first.path, Self.firstText)) {
            $0.previousText = Self.firstText
            $0.previousPages = firstPages
        }
        return firstPages
    }

    // MARK: - 1. 已就绪：直接换章（不转圈）

    /// 已就绪 ⇒ **不经过** `loadChapterWithName`，所以 `isLoading` 全程为假 ——
    /// 下面 `send` 的断言闭包里**没有** `isLoading = true`，回退路径一旦被走到就会红。
    func test下一章已就绪时直接换章不转圈() async {
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText]
        )
        let secondPages = await loadFirstAndPreloadSecond(store)
        // ⚠️ 刻意**不**推到最后一页：按钮在任意页都要能按（这是它与章尾左滑的唯一差别）。
        XCTAssertEqual(store.state.currentPageIndex, 0, "前置条件：还停在第 1 页")

        await store.send(.jumpToAdjacentChapter(Self.second)) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = 0
            $0.nextText = ""
            $0.nextPages = []
        }
        // 链式：换到第 2 章（末章）后，新的上一章（第 1 章）接上；没有下一章可接。
        await store.receive(.previousChapterLoaded(Self.first.path, Self.firstText)) {
            $0.previousText = Self.firstText
            $0.previousPages = expectedPages(chapter: Self.first, text: Self.firstText)
        }
        await store.finish()

        XCTAssertFalse(store.state.isLoading, "走预加载就绪那条路：全程不转圈")
        XCTAssertEqual(store.state.chapterPath, Self.second.path)
        XCTAssertEqual(store.state.currentOffset, 0, "落到新章章首（契约③：存字符偏移）")
        XCTAssertEqual(store.state.currentPageIndex, 0)
    }

    // MARK: - 2. 任意页都能按（与章尾左滑的差别）

    /// 中间页也要能换 —— 这正是按钮**不能**复用 `.advanceChapter` 的原因：
    /// 那个 `guard currentPageIndex == pages.count - 1`，中间页按下去什么都不做。
    func test中间页按下一章也能直接换章() async {
        let store = makeStore(
            chapters: [Self.first, Self.second, Self.third],
            texts: [
                Self.first.path: Self.firstText,
                Self.second.path: Self.secondText,
                Self.third.path: Self.thirdText,
            ]
        )
        let secondPages = await loadFirstAndPreloadSecond(store)
        let firstPages = expectedPages(chapter: Self.first, text: Self.firstText)
        XCTAssertGreaterThan(firstPages.count, 2, "前置条件：样本 3 页 ⇒ 第 2 页是中间页")
        await store.send(.nextPage) { $0.currentOffset = firstPages[1].location }
        XCTAssertEqual(store.state.currentPageIndex, 1, "前置条件：停在中间页")

        // 对比：章尾左滑那条路在中间页**原地不动**（它只服务「已经在最后一页」）。
        await store.send(.advanceChapter)
        XCTAssertEqual(store.state.currentOffset, firstPages[1].location, "章尾左滑在中间页不动")

        await store.send(.jumpToAdjacentChapter(Self.second)) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = 0
            $0.nextText = ""
            $0.nextPages = []
        }
        await store.receive(.nextChapterLoaded(Self.third.path, Self.thirdText)) {
            $0.nextText = Self.thirdText
            $0.nextPages = expectedPages(chapter: Self.third, text: Self.thirdText)
        }
        await store.receive(.previousChapterLoaded(Self.first.path, Self.firstText)) {
            $0.previousText = Self.firstText
            $0.previousPages = firstPages
        }
        await store.finish()

        XCTAssertEqual(store.state.chapterPath, Self.second.path)
        XCTAssertEqual(store.state.currentOffset, 0, "按钮换章一律落到新章章首（与完整加载同页）")
        XCTAssertEqual(store.state.currentPageIndex, 0)
        XCTAssertFalse(store.state.isLoading, "同样不转圈")
    }

    // MARK: - 3. 未就绪：回退完整加载（转圈）

    /// 未就绪 ⇒ 回退 `loadChapterWithName`：`isLoading` 被置 true ——
    /// **这就是与就绪那条路唯一的可观测差别**，行为与改动前完全一致。
    ///
    /// 「未就绪」用「分页为空」构造而不是「读失败」：两者都会让 reducer 丢掉预加载结果
    /// （口径见 `ReaderChapterAdvanceTests.test下一章分页为空时安静留空`），但读失败会让
    /// **回退**也失败 ⇒ 断言得依赖 `localizedDescription` 的文案，脆。
    func test下一章未就绪时回退完整加载并转圈() async {
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
        // 正文收到了，但分页为空 ⇒ 状态里什么都没留下 ⇒ 按钮那一侧「未就绪」。
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText))
        XCTAssertTrue(store.state.nextPages.isEmpty, "前置条件：下一章未就绪")

        // ⚠️ 这里**刻意不带状态闭包**：未就绪时走的是回退分支，而它返回
        // `Effect.send(.loadChapterWithName(...))` —— 那是**重新进 store 的一个新 action**，
        // 状态变化发生在 store 处理它那一刻，**不在**这一次 `send` 里。
        // 「不带闭包」本身就是断言：未就绪时按钮这一步**不改任何状态**。
        await store.send(.jumpToAdjacentChapter(Self.second))
        // 回退路径的后续与「从目录手动跳章」逐字相同（分页桩让这一章同样分不出页）：
        // 这份期望态与 `ReaderChapterAdvanceTests.test手动跳章时旧的下一章结果作废` 里
        // 直接发 `.loadChapterWithName` 的那份**逐值相同** —— 回退没有改变任何行为。
        await store.receive(.loadChapterWithName(Self.second.path, Self.second.name)) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded(Self.secondText)) {
            $0.text = Self.secondText
            $0.isLoading = false
        }
        await store.receive(.previousChapterLoaded(Self.first.path, Self.firstText)) {
            $0.previousText = Self.firstText
            $0.previousPages = expectedPages(chapter: Self.first, text: Self.firstText)
        }
        await store.finish()

        XCTAssertFalse(store.state.isLoading)
        XCTAssertEqual(store.state.chapterPath, Self.second.path, "兜底也要真的换过去")
        XCTAssertEqual(store.state.currentOffset, 0, "兜底也落到新章章首（与就绪那条路同页）")
        XCTAssertTrue(store.state.pages.isEmpty, "分页桩让这一章分不出页（本用例不关心它的分页）")
    }

    // MARK: - 4. 上一章按钮的落页口径

    /// 上一章按钮落到上一章**第 1 页**（`offset = 0`），**不是**末页。
    ///
    /// 「章首退上一章」（`.retreatChapter`）才落末页 —— 那条要接在上一章章尾之后。
    /// 按钮必须与完整加载落同一页，否则「预加载有没有就绪」会让同一个按钮跳到不同的页。
    func test上一章按钮落到上一章第1页而不是末页() async {
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText]
        )
        let secondPages = await loadFirstAndPreloadSecond(store)
        // 先跳到第 2 章，让「上一章（第 1 章）」就绪。
        let firstPages = await jumpToSecondAndPreloadFirst(store, secondPages: secondPages)
        XCTAssertGreaterThan(firstPages.count, 1, "前置条件：上一章要多页，否则章首与末页分不出来")
        XCTAssertNotEqual(firstPages.last?.location ?? 0, 0, "前置条件：末页页首偏移不是 0")

        // 按「上一章」：回到第 1 章的**第 1 页**。
        await store.send(.jumpToAdjacentChapter(Self.first)) {
            $0.chapterPath = Self.first.path
            $0.chapterName = Self.first.name
            $0.text = Self.firstText
            $0.pages = firstPages
            $0.currentOffset = 0
            // 两侧都换了对象 ⇒ 都作废（上一章此刻非空，这条同时锁住「不留下旧值」）。
            $0.previousText = ""
            $0.previousPages = []
        }
        // 链式：回到第 1 章后，下一章（第 2 章）重新接上；第 1 章没有上一章。
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = secondPages
        }
        await store.finish()

        XCTAssertEqual(store.state.chapterPath, Self.first.path)
        XCTAssertEqual(store.state.currentOffset, 0, "按钮语义 = 上一章章首")
        XCTAssertEqual(store.state.currentPageIndex, 0)
        XCTAssertNotEqual(
            store.state.currentOffset,
            firstPages.last?.location ?? 0,
            "不是「章首退上一章」那条路（那条落末页）"
        )
        XCTAssertFalse(store.state.isLoading)
    }
}

// MARK: - 夹具（文件级，不占 `type_body_length`）

/// 夹具的可选旋钮：收成一个值类型，避免 `makeStore` 的参数个数越线
/// （`function_parameter_count` warning 5 / error 8，CI `--strict` 下 warning 即失败）。
private struct StoreOptions {
    var failing: Set<String> = []
    var paginate: (@Sendable (String, PaginationConfiguration) -> [PageRange])?
    var cache: (@Sendable (String, String, Int) async -> Void)?
}

/// 分页桩：宽预算 10 ⇒ 纯正文页每页 5 个中文（`FakeMeasuring` 里中文宽 2、ASCII 宽 1）；
/// 首页被章名（宽 6）与两个换行（宽 2）占掉大半，只放得下 1 个中文 ⇒ 共 6 个字符。
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
