import ComposableArchitecture
@testable import NovelCore
import XCTest

/// 「到章首无缝退上一章」的 reducer 侧用例 —— `ReaderChapterAdvanceTests`（章尾进下一章）的镜像。
///
/// 单独一个文件（而不是塞进 `ReaderChapterAdvanceTests`）：那个文件已经 468 行、
/// 贴着 SwiftLint `file_length` 600 的 warning 线（CI `--strict` 下 warning 即失败），
/// 装不下这一组。夹具刻意**自成一份**：跨文件复用就得把另一份的 `private` 夹具
/// 全部放开成 internal，改动面反而更大。
///
/// 样本与 `ReaderChapterAdvanceTests` 同口径：每章「章名 + 10 个中文」、宽预算 10 ⇒ 3 页，
/// 页首偏移 **0 / 6 / 11**（一律从 `expectedPages(chapter:text:)` 推，不写死数字）。
@MainActor
final class ReaderChapterRetreatTests: XCTestCase {
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
            // 进度与缓存都换成空桩：本文件只关心状态迁移与「补一次缓存」的次数。
            $0.readingProgressStore.markRead = { _, _, _ in }
            $0.chapterCacheStore.cacheCurrentAndFollowing = options.cache ?? { _, _, _ in }
            $0.paginationService.paginate = options.paginate ?? paginateWithBudgetTen
        }
    }

    /// 走正常开章路径加载一章（`loadChapterWithName` + `contentLoaded`）。
    ///
    /// 闭包里显式清空相邻两章的预加载结果：换章（含从目录手动跳章）会作废它们，
    /// 不清空就会在下一次 `send` 上以「状态不匹配」的形式红，而不是让断言错得莫名其妙。
    ///
    /// ⚠️ **例外是「刚离开的那一章」**：换章后它就是新章的一侧邻居，reducer 会把它的正文
    /// 与整章分页直接搬过去（`installLeavingChapter`）⇒ 这里按同一条口径把那一侧补上。
    /// 哪一侧、以及「远侧仍作废」，由 `ReaderChapterPanSlotTests` 用写死的期望值钉住；
    /// 本夹具只负责让前置状态与 reducer 一致。
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

    /// 收下「上一章」预加载结果，返回它的分页。
    @discardableResult
    private func receivePrevious(
        _ store: TestStore<ReaderFeature.State, ReaderFeature.Action>,
        chapter: ChapterItem,
        text: String
    ) async -> [PageRange] {
        let pages = expectedPages(chapter: chapter, text: text)
        await store.receive(.previousChapterLoaded(chapter.path, text)) {
            $0.previousText = text
            $0.previousPages = pages
        }
        return pages
    }

    // MARK: - 1. 章首退章

    /// 🔴 核心：第 2 章第一页继续往右滑 ⇒ 退到第 1 章**最后一页**。
    ///
    /// `currentOffset` 必须是上一章末页页首的**字符偏移**（不是 0）—— 契约③，
    /// 也是与 `advanceChapter`（新章从章首开始）唯一的实质差别。
    func test章首退章切到上一章最后一页() async {
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText]
        )
        await load(store, chapter: Self.second, text: Self.secondText)
        let firstPages = await receivePrevious(store, chapter: Self.first, text: Self.firstText)
        XCTAssertEqual(store.state.currentPageIndex, 0, "前置条件：已在第 2 章第一页")
        XCTAssertFalse(store.state.previousPages.isEmpty, "前置条件：上一章最后一页已就绪")

        await store.send(.retreatChapter) {
            $0.chapterPath = Self.first.path
            $0.chapterName = Self.first.name
            $0.text = Self.firstText
            $0.pages = firstPages
            $0.currentOffset = firstPages.last?.location ?? 0
            // 先清空再重算：旧值绝不能被当成新章的「上一章」。
            $0.previousText = ""
            $0.previousPages = []
            // 刚离开的第 2 章就是新的下一章 ⇒ 它的正文与整章分页直接搬过来（内存里现成的），
            // 不必等预加载。远侧（上一章）仍按上面两行作废 —— 它现在指向的是别的章。
            $0.nextText = Self.secondText
            $0.nextPages = expectedPages(chapter: Self.second, text: Self.secondText)
        }
        // 反向链式：退到第 1 章后，它的下一章（第 2 章）重新接上 —— 它已经在槽位里
        // （上面搬过去的）⇒ 这一份逐值相同、状态不变 ⇒ 不带断言闭包。
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText))
        await store.finish()

        XCTAssertEqual(store.state.chapterPath, Self.first.path)
        XCTAssertEqual(store.state.chapterName, Self.first.name)
        XCTAssertEqual(store.state.pages, firstPages)
        XCTAssertEqual(store.state.currentOffset, firstPages.last?.location, "落在上一章末页页首")
        XCTAssertNotEqual(store.state.currentOffset, 0, "不是章首：存的是末页的字符偏移")
        XCTAssertEqual(store.state.currentPageIndex, firstPages.count - 1, "落在上一章最后一页")
        XCTAssertNil(store.state.previousChapter, "列表只有两章：第 1 章之前没有上一章")
    }

    /// 首章第一页继续往右滑 ⇒ 退章 action **不改变状态**（回弹，不提示）。
    ///
    /// 与末章对称：判据是 `previousChapter` 为 `nil`（第一章 / 列表里找不到当前章），
    /// 不看页码 —— 所以这里连 `.retreatChapter` 之后的状态都不需要断言闭包。
    func test首章第一页退章不改变状态() async {
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText]
        )
        await load(store, chapter: Self.first, text: Self.firstText)
        // 开章后预加载的是下一章（第 1 章没有上一章）。
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText)) {
            $0.nextText = Self.secondText
            $0.nextPages = expectedPages(chapter: Self.second, text: Self.secondText)
        }
        XCTAssertNil(store.state.previousChapter, "前置条件：第 1 章没有上一章")

        await store.send(.retreatChapter)
        await store.finish()
        XCTAssertEqual(store.state.chapterPath, Self.first.path)
        XCTAssertEqual(store.state.currentOffset, 0, "回弹：位置仍停在章首")
        XCTAssertNil(store.state.errorMessage, "不提示：没有上一章不产生任何错误文案")
    }

    // MARK: - 2. 拿不到上一章时安静失败

    /// 上一章正文读失败 ⇒ 状态不变、不报错（`finish()` 同时证明没有冒出 `loadFailed`）。
    func test上一章加载失败时安静留空() async {
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.second.path: Self.secondText],
            options: StoreOptions(failing: [Self.first.path])
        )
        await load(store, chapter: Self.second, text: Self.secondText)
        await store.finish()

        XCTAssertTrue(store.state.previousText.isEmpty)
        XCTAssertTrue(store.state.previousPages.isEmpty)
        XCTAssertNil(store.state.errorMessage)

        await store.send(.retreatChapter)
        await store.finish()
        XCTAssertEqual(store.state.chapterPath, Self.second.path, "没就绪就不换章")
    }

    /// 上一章分页为空 ⇒ 同样安静留空：拿到了正文但没有可用的页，也不换章。
    func test上一章分页为空时安静留空() async {
        // 标记取成局部量：分页桩是 `@Sendable` 闭包，读不了 `@MainActor` 类的静态属性。
        let marker = Self.firstText
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText],
            options: StoreOptions(paginate: { text, config in
                // 只让上一章分不出页（它的渲染文本里带着这一章的正文）。
                text.contains(marker) ? [] : paginateWithBudgetTen(text, config)
            })
        )
        await load(store, chapter: Self.second, text: Self.secondText)
        // 正文拿到了、分页为空 ⇒ reducer 收到结果后仍不动状态（所以断言闭包为空）。
        await store.receive(.previousChapterLoaded(Self.first.path, Self.firstText))
        await store.finish()

        XCTAssertTrue(store.state.previousText.isEmpty, "分页为空 ⇒ 正文也不留下（半份状态比没有更危险）")
        XCTAssertTrue(store.state.previousPages.isEmpty)
        XCTAssertNil(store.state.errorMessage)

        await store.send(.retreatChapter)
        await store.finish()
        XCTAssertEqual(store.state.chapterPath, Self.second.path, "没就绪就不换章")
    }
}

// MARK: - 链式 / 跳章作废 / 补缓存（放 extension：`type_body_length` 不计 extension）

extension ReaderChapterRetreatTests {
    // MARK: - 3. 链式：退章后重新预加载新的上一章

    /// 直接开第 3 章：它的上一章（第 2 章）在本章 `contentLoaded` 后就预加载好了；
    /// 退到第 2 章后，reducer 又把**新的**上一章（第 1 章）接上。
    ///
    /// ⚠️ `receive` 的顺序：相邻两章的预加载由 `preloadAdjacentChapters` **串行**发出
    /// （先下一章、后上一章）—— 顺序是代码里定死的，不是并发到达的巧合。
    func test退章后重新预加载新的上一章() async {
        let store = makeStore(
            chapters: [Self.first, Self.second, Self.third],
            texts: [
                Self.first.path: Self.firstText,
                Self.second.path: Self.secondText,
                Self.third.path: Self.thirdText,
            ]
        )
        await load(store, chapter: Self.third, text: Self.thirdText)
        let secondPages = await receivePrevious(store, chapter: Self.second, text: Self.secondText)
        XCTAssertEqual(store.state.previousChapter?.path, Self.second.path, "前置条件：上一章已就绪")

        await store.send(.retreatChapter) {
            $0.chapterPath = Self.second.path
            $0.chapterName = Self.second.name
            $0.text = Self.secondText
            $0.pages = secondPages
            $0.currentOffset = secondPages.last?.location ?? 0
            // 远侧（新的上一章）作废；刚离开的第 3 章落进新的下一章槽位。
            $0.previousText = ""
            $0.previousPages = []
            $0.nextText = Self.thirdText
            $0.nextPages = expectedPages(chapter: Self.third, text: Self.thirdText)
        }
        // 链式（反向）：它的下一章（第 3 章）先重新接上 —— 已经在槽位里（上面搬过去的）
        // ⇒ 这一份逐值相同、状态不变 ⇒ 不带断言闭包。
        await store.receive(.nextChapterLoaded(Self.third.path, Self.thirdText))
        // 链式：退到第 2 章那一刻就重新声明了它的上一章（第 1 章）并重新预加载。
        let firstPages = await receivePrevious(store, chapter: Self.first, text: Self.firstText)
        await store.finish()

        XCTAssertEqual(store.state.chapterPath, Self.second.path)
        XCTAssertEqual(store.state.currentOffset, secondPages.last?.location, "落在上一章末页页首")
        XCTAssertEqual(store.state.previousChapter?.path, Self.first.path)
        XCTAssertEqual(store.state.previousPages, firstPages)
        XCTAssertEqual(store.state.nextChapter?.path, Self.third.path)
    }

    // MARK: - 4. 手动跳章：旧的上一章结果必须作废

    /// 从第 2 章跳到第 3 章：第 1 章那份 `previousPages`（此刻指向**远侧**，因为第 3 章的
    /// 上一章换成了第 2 章）必须当场作废（`load` 的断言闭包锁住这一步），而**刚离开的
    /// 第 2 章**紧接着就被搬进同一侧 —— 它的分页在内存里，不必等预加载。
    func test手动跳章时旧的上一章结果作废() async {
        let store = makeStore(
            chapters: [Self.first, Self.second, Self.third],
            texts: [
                Self.first.path: Self.firstText,
                Self.second.path: Self.secondText,
                Self.third.path: Self.thirdText,
            ]
        )
        await load(store, chapter: Self.second, text: Self.secondText)
        // 第 2 章开章后：下一章（第 3 章）与上一章（第 1 章）都预加载好了。
        await store.receive(.nextChapterLoaded(Self.third.path, Self.thirdText)) {
            $0.nextText = Self.thirdText
            $0.nextPages = expectedPages(chapter: Self.third, text: Self.thirdText)
        }
        await receivePrevious(store, chapter: Self.first, text: Self.firstText)
        XCTAssertEqual(store.state.previousChapter?.path, Self.first.path, "前置条件：旧的上一章是第 1 章")

        // 从目录直接跳到第 3 章：第 1 章那份预加载结果必须同时被清掉（`load` 的断言闭包
        // 锁住这一步）；刚离开的第 2 章已经被直接搬进这一侧 ⇒ 下面这一份预加载结果与它
        // 逐值相同、**状态不变** ⇒ 不带断言闭包（带闭包时 TCA 会要求状态真的变了）。
        await load(store, chapter: Self.third, text: Self.thirdText)
        let secondPages = expectedPages(chapter: Self.second, text: Self.secondText)
        await store.receive(.previousChapterLoaded(Self.second.path, Self.secondText))
        await store.finish()

        XCTAssertEqual(store.state.chapterPath, Self.third.path)
        XCTAssertEqual(store.state.previousChapter?.path, Self.second.path)
        XCTAssertEqual(store.state.previousPages, secondPages, "换成第 3 章的上一章（第 2 章），不是旧的")
    }

    // MARK: - 5. 退章也要补一次自动缓存

    /// 退章成功后，缓存依赖被调用**一次**，入参是「新章（上一章）路径 + 正文 + 当前 precacheCount」。
    func test退章后按新章补一次自动缓存() async {
        let recorder = CacheCallRecorder()
        let store = makeStore(
            chapters: [Self.first, Self.second],
            texts: [Self.first.path: Self.firstText, Self.second.path: Self.secondText],
            options: StoreOptions(cache: { path, text, count in
                await recorder.record(path: path, text: text, count: count)
            })
        )
        await load(store, chapter: Self.second, text: Self.secondText)
        let firstPages = await receivePrevious(store, chapter: Self.first, text: Self.firstText)
        // 正常开章（`contentLoaded`）那一次已经记完；清空后只数退章这一次。
        await recorder.reset()

        await store.send(.retreatChapter) {
            $0.chapterPath = Self.first.path
            $0.chapterName = Self.first.name
            $0.text = Self.firstText
            $0.pages = firstPages
            $0.currentOffset = firstPages.last?.location ?? 0
            // 远侧（新的上一章）作废；刚离开的第 2 章直接落进新的下一章槽位
            // —— 这不产生缓存调用，下面「退章只补一次缓存」的计数不受影响。
            $0.previousText = ""
            $0.previousPages = []
            $0.nextText = Self.secondText
            $0.nextPages = expectedPages(chapter: Self.second, text: Self.secondText)
        }
        // 这一份与上面**搬过来的**逐值相同 ⇒ 状态不变 ⇒ 不带断言闭包。
        await store.receive(.nextChapterLoaded(Self.second.path, Self.secondText))
        await store.finish()

        let requests = await recorder.allRequests()
        XCTAssertEqual(requests.count, 1, "退章只补一次缓存")
        XCTAssertEqual(requests.first?.path, Self.first.path, "缓存的是新章（上一章），不是刚离开的那一章")
        XCTAssertEqual(requests.first?.text, Self.firstText, "落盘的是新章正文")
        XCTAssertEqual(
            requests.first?.count,
            ReaderFeature.defaultPrecacheCount,
            "沿用当前 precacheCount（本用例没改过设置）"
        )
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

/// 记录自动缓存调用（spy）：退章用例要先扣掉正常开章那一次，才能把「退章补缓存」单独数出来。
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
