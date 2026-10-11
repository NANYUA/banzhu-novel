import ComposableArchitecture
@testable import NovelCore
import XCTest

/// 「换章后，刚读过的那一章留在滑动方向上的那个相邻槽位」的 reducer 侧用例。
///
/// ## 背景（owner 真机反馈，逐字）
/// 「切换章节的时候刚刚阅读的章节正文会消失，导致观感不佳，所以既然缓存不删除就不必让
/// 刚刚读过的正文消失（切换上一章或者下一章）」。
/// 现象是**换章之后，刚读过的那一章在滑动方向上是空白** —— 马上往回滑（或往前滑回去）
/// 看不到刚才那一页，要等重新预加载才出现。
///
/// ## 为什么这不是缓存问题
/// 磁盘缓存是好的。原因是换章时**内存里的相邻章状态被清空**：迁移体先
/// `invalidateNextChapter` + `invalidatePreviousChapter`（两侧都清），再靠
/// `preloadAdjacentChapters` 重新取 —— 而刚离开的那一章此刻正好是其中一侧
/// （往前换 ⇒ 它是新的上一章；往回换 ⇒ 它是新的下一章）⇒ 那一侧在预加载回来之前是空的。
///
/// ## 为什么「直接搬」是对的
/// 刚离开那一章的正文（`text`）与**整章分页**（`pages`）本来就在内存里，而且分页与正文
/// **同源**（同一份 `displayText` + 同一份 config 算出来的）⇒ 原样搬到 `previousPages` /
/// `nextPages` 就是那一章的合法分页：不必重新读盘 / 联网，也不必重新分页。
/// 而**另一侧必须仍然作废** —— 换章后两侧的对象都换了，远侧现在指向的是**别的章**，
/// 旧值留着就是错正文（那正是两个 `invalidate*Chapter` 存在的理由）。
///
/// ## 与三个换章用例文件的分工
/// `ReaderChapterAdvanceTests` / `ReaderChapterRetreatTests` / `ReaderChapterJumpTests`
/// 锁的是「换章换得对不对」（落到哪一章、哪一页、链式预加载、补缓存）；
/// 本文件只锁**两个相邻槽位**的口径，且用**写死的期望值**（期望态里直接写旧章的正文与
/// 分页，不调用 reducer 的判定逻辑）⇒ 「搬错侧」「两侧都搬」「两侧都不搬」都会立刻红。
///
/// 样本与那三个文件同口径：每章「章名 + 10 个中文」、宽预算 10 ⇒ 3 页，
/// 页首偏移 **0 / 6 / 11**（一律从 `expectedPages(chapter:text:)` 推，不写死数字）。
@MainActor
final class ReaderChapterPanSlotTests: XCTestCase {
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
        texts: [String: String]
    ) -> TestStore<ReaderFeature.State, ReaderFeature.Action> {
        TestStore(
            initialState: ReaderFeature.State(chapterPath: Self.first.path, chapters: chapters)
        ) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = { path in
                guard let text = texts[path] else { throw ChapterLoadError.unavailable }
                return text
            }
            // 进度与缓存都换成空桩：本文件只关心两个相邻槽位的内容。
            $0.readingProgressStore.markRead = { _, _, _ in }
            $0.chapterCacheStore.cacheCurrentAndFollowing = { _, _, _ in }
            $0.paginationService.paginate = paginateWithBudgetTen
        }
    }

    /// 三章样本的 store（两个用例的初始状态相同）。
    private func makeThreeChapterStore() -> TestStore<ReaderFeature.State, ReaderFeature.Action> {
        makeStore(
            chapters: [Self.first, Self.second, Self.third],
            texts: [
                Self.first.path: Self.firstText,
                Self.second.path: Self.secondText,
                Self.third.path: Self.thirdText,
            ]
        )
    }

    /// 走正常开章路径加载一章（`loadChapterWithName` + `contentLoaded`）。
    ///
    /// `loadChapterWithName` 现在也会把「刚离开那一章」搬进它该在的那一侧
    /// （跳章条「相邻章未就绪」的兜底走的就是这条），所以期望态要按同一条口径写。
    private func load(
        _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>,
        chapter: ChapterItem,
        text: String
    ) async {
        // ⚠️ 必须在 send 之前取：`send` 一过，`chapterPath` 就指向新章了。
        let leavingPath = store.state.chapterPath
        let leavingText = store.state.text
        let leavingPages = store.state.pages
        await store.send(.loadChapterWithName(chapter.path, chapter.name)) {
            $0.chapterPath = chapter.path
            $0.chapterName = chapter.name
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
            $0.previousText = ""
            $0.previousPages = []
            $0.nextText = ""
            $0.nextPages = []
            if $0.previousChapter?.path == leavingPath {
                $0.previousText = leavingText
                $0.previousPages = leavingPages
            } else if $0.nextChapter?.path == leavingPath {
                $0.nextText = leavingText
                $0.nextPages = leavingPages
            }
        }
        await store.receive(.contentLoaded(text)) {
            $0.text = text
            $0.isLoading = false
            $0.pages = expectedPages(chapter: chapter, text: text)
            $0.currentOffset = 0
        }
    }

    /// 公共前导（往前换章用）：开第 1 章 → 收下下一章（第 2 章）→ 推到第 1 章**最后一页**。
    private func readyToAdvanceFromFirst(
        _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>
    ) async {
        let firstPages = expectedPages(chapter: Self.first, text: Self.firstText)
        await store.send(.loadChapterWithName(Self.first.path, Self.first.name)) {
            $0.chapterName = Self.first.name
            $0.isLoading = true
        }
        await store.receive(.contentLoaded(Self.firstText)) {
            $0.text = Self.firstText
            $0.isLoading = false
            $0.pages = firstPages
            $0.currentOffset = 0
        }
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = expectedPages(chapter: Self.second, text: Self.secondText)
        }
        for index in firstPages.indices.dropFirst() {
            await store.send(.nextPage) { $0.currentOffset = firstPages[index].location }
        }
    }

    // MARK: - 1. 往前换章：刚离开的那一章落在 `previousPages`

    /// 第 1 章章尾进第 2 章 ⇒ **还没收到任何预加载结果**时，第 1 章的正文与整章分页
    /// 就应该已经在 `previousText` / `previousPages` 上（这正是「马上往回滑不再空白」）。
    ///
    /// 同时锁住**远侧仍作废**：第 2 章的下一章是第 3 章，`nextPages` 里绝不能留着
    /// 换章前那份（那是第 2 章自己的分页，不是第 3 章的）—— 留着就会被全景图当成第 3 章切页。
    func test往前换章后刚读过的上一章直接就在上一章槽位() async {
        let store = makeThreeChapterStore()
        let firstPages = expectedPages(chapter: Self.first, text: Self.firstText)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        let thirdPages = expectedPages(chapter: Self.third, text: Self.thirdText)
        await readyToAdvanceFromFirst(store)
        XCTAssertEqual(store.state.currentPageIndex, firstPages.count - 1, "前置条件：已在第 1 章最后一页")

        await store.send(.advanceChapter) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = 0
            $0.nextText = ""
            $0.nextPages = []
            $0.previousText = Self.firstText
            $0.previousPages = firstPages
        }

        // 🔴 本用例要钉的（都发生在收到任何预加载结果**之前**）：
        XCTAssertEqual(store.state.previousChapter?.path, Self.first.path, "刚离开的第 1 章就是新的上一章")
        XCTAssertEqual(store.state.previousText, Self.firstText, "正文是内存里现成的那一份")
        XCTAssertEqual(store.state.previousPages, firstPages, "分页与旧章逐值相同（同源，不必重算）")
        XCTAssertFalse(store.state.previousPages.isEmpty, "非空 ⇒ 往回滑立刻有内容")
        XCTAssertEqual(store.state.previousPages.count, firstPages.count, "页数与旧章一致")
        XCTAssertEqual(store.state.previousPages.first?.location, firstPages.first?.location, "页首偏移与旧章一致（0）")
        // ⛔ 远侧（新的下一章 = 第 3 章）必须仍被作废：它此刻还没有内容可给。
        XCTAssertTrue(store.state.nextText.isEmpty, "远侧作废：正文不留（旧值是别的章）")
        XCTAssertTrue(store.state.nextPages.isEmpty, "远侧作废：分页不留")

        // 远侧由链式预加载取回来（第 3 章）—— 它是真变化，带断言闭包；
        // 近侧（第 1 章）已经在槽位里（上面搬过去的）⇒ 预加载结果逐值相同、状态不变
        // ⇒ 不带断言闭包（带闭包时 TCA 会要求状态真的变了）。
        await store.receive(.nextChapterLoaded(Self.third.path, Self.thirdText)) {
            $0.nextText = Self.thirdText
            $0.nextPages = thirdPages
        }
        await store.receive(.previousChapterLoaded(Self.first.path, Self.firstText))
        await store.finish()
        XCTAssertEqual(store.state.nextChapter?.path, Self.third.path, "远侧最终是第 3 章，不是旧值")
    }

    // MARK: - 2. 往回换章：刚离开的那一章落在 `nextPages`

    /// 第 3 章章首退到第 2 章 ⇒ **还没收到任何预加载结果**时，第 3 章的正文与整章分页
    /// 就应该已经在 `nextText` / `nextPages` 上（往前滑回去不再空白）。
    ///
    /// 同时锁住**远侧仍作废**：第 2 章的上一章是第 1 章，`previousPages` 里绝不能留着
    /// 换章前那份（第 2 章自己的分页）—— 留着就会被当成第 1 章往回翻。
    func test往回换章后刚读过的下一章直接就在下一章槽位() async {
        let store = makeThreeChapterStore()
        let firstPages = expectedPages(chapter: Self.first, text: Self.firstText)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        let thirdPages = expectedPages(chapter: Self.third, text: Self.thirdText)
        // 直接开第 3 章：它的上一章（第 2 章）由本章 `contentLoaded` 预加载（它没有下一章）。
        await load(store, chapter: Self.third, text: Self.thirdText)
        await store.receive(.previousChapterLoaded(Self.second.path, Self.secondText)) {
            $0.previousText = Self.secondText
            $0.previousPages = secondPages
        }
        XCTAssertEqual(store.state.currentPageIndex, 0, "前置条件：已在第 3 章第一页")

        await store.send(.retreatChapter) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = secondPages.last?.location ?? 0
            $0.previousText = ""
            $0.previousPages = []
            $0.nextText = Self.thirdText
            $0.nextPages = thirdPages
        }

        // 🔴 本用例要钉的（都发生在收到任何预加载结果**之前**）：
        XCTAssertEqual(store.state.nextChapter?.path, Self.third.path, "刚离开的第 3 章就是新的下一章")
        XCTAssertEqual(store.state.nextText, Self.thirdText, "正文是内存里现成的那一份")
        XCTAssertEqual(store.state.nextPages, thirdPages, "分页与旧章逐值相同（同源，不必重算）")
        XCTAssertFalse(store.state.nextPages.isEmpty, "非空 ⇒ 往前滑回去立刻有内容")
        XCTAssertEqual(store.state.nextPages.count, thirdPages.count, "页数与旧章一致")
        XCTAssertEqual(store.state.nextPages.first?.location, thirdPages.first?.location, "页首偏移与旧章一致（0）")
        // ⛔ 远侧（新的上一章 = 第 1 章）必须仍被作废：它此刻还没有内容可给。
        XCTAssertTrue(store.state.previousText.isEmpty, "远侧作废：正文不留（旧值是别的章）")
        XCTAssertTrue(store.state.previousPages.isEmpty, "远侧作废：分页不留")

        // 近侧（第 3 章）已经在槽位里（上面搬过去的）⇒ 预加载结果逐值相同、状态不变
        // ⇒ 不带断言闭包；远侧（第 1 章）是真变化，带断言闭包。
        await store.receive(.nextChapterLoaded(Self.third.path, Self.thirdText))
        await store.receive(.previousChapterLoaded(Self.first.path, Self.firstText)) {
            $0.previousText = Self.firstText
            $0.previousPages = firstPages
        }
        await store.finish()
        XCTAssertEqual(store.state.previousChapter?.path, Self.first.path, "远侧最终是第 1 章，不是旧值")
    }
}

// MARK: - 夹具（文件级，不占 `type_body_length`）

/// 分页桩：宽预算 10 ⇒ 纯正文页每页 5 个中文（`FakeMeasuring` 里中文宽 2、ASCII 宽 1）；
/// 首页被章名（宽 6）与两个换行（宽 2）占掉大半，只放得下 1 个中文 ⇒ 共 6 个字符。
private let paginateWithBudgetTen: @Sendable (String, PaginationConfiguration) -> [PageRange] = { text, configuration in
    Paginator(measurer: FakeMeasuring(widthBudget: 10))
        .paginate(text: text, configuration: configuration)
}

/// 期望分页用的配置：与 `ReaderFeature.State` 的默认值同源（用例里没有任何改设置动作）。
private let defaultConfiguration = ReaderFeature.State(chapterPath: "/1/1.html").config

/// 期望分页的**独立**算法：这里自己把「章名 + 正文」拼出来（而不是问 reducer 要
/// `displayText`）—— 搬过来的分页若漏了章名或换了 config，期望值就与它对不上。
private func expectedPages(chapter: ChapterItem, text: String) -> [PageRange] {
    paginateWithBudgetTen(chapter.name + "\n\n" + text, defaultConfiguration)
}

/// 预加载失败用的错误：用例只关心「抛了」，不关心文案 —— 安静失败本就不该暴露任何文案。
private enum ChapterLoadError: Error {
    case unavailable
}
