import ComposableArchitecture
import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 阅读进度「读回」与「首次加载恢复位置」测试。
///
/// 覆盖三件事：
/// 1. `ReadingProgressStoreLive` 的**落盘 / 读回**规则 —— 写的是传入的 `offset`（不是恒 0），
///    读回时「章节路径与章名都非空」才算有记录；
/// 2. `ReaderFeature` 只在**首次** `contentLoaded` 时按 `initialOffset` 恢复位置，
///    恢复一次后归零 ⇒ 换章 / 从目录跳章仍从章首开始（既有语义不变）；
/// 3. 🔴 **两个坐标系的换算**：`initialOffset` 是落盘口径（相对原始正文），
///    而 `currentOffset` / `displayText` 含章名前缀 ⇒ 恢复时要加回 `titlePrefixLength`。
///
/// 容器一律用 `NovelStore.makeContainer(inMemory: true)`（先例 `ReaderCacheHealTests`），
/// 走 `ReadingProgressStoreLive` 的**可注入容器**重载，不碰真实沙盒。
@MainActor
final class ReadingProgressTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try NovelStore.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    // MARK: - 读回：完整记录 / 半条记录 / 书不存在

    func test读回完整进度() throws {
        let book = BookRecord(bookPath: "/progress/full/", title: "测试书")
        book.lastReadChapterPath = "/progress/full/7.html"
        book.lastReadChapterName = "第七章"
        book.lastReadOffset = 137
        context.insert(book)
        try context.save()

        let progress = try ReadingProgressStoreLive.load(bookPath: book.bookPath, in: context)

        XCTAssertEqual(progress?.chapterPath, "/progress/full/7.html")
        XCTAssertEqual(progress?.chapterName, "第七章")
        XCTAssertEqual(progress?.offset, 137)
    }

    /// `offset` 为 0 也是合法进度（第一章第一页），**不能**当成「没记录」。
    func test偏移为零仍算有记录() throws {
        let book = BookRecord(bookPath: "/progress/zero/", title: "测试书")
        book.lastReadChapterPath = "/progress/zero/1.html"
        book.lastReadChapterName = "第一章"
        book.lastReadOffset = 0
        context.insert(book)
        try context.save()

        let progress = try ReadingProgressStoreLive.load(bookPath: book.bookPath, in: context)

        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.offset, 0)
    }

    /// 半条记录（缺章节路径 / 缺章名 / 章名为空串）一律当「没读过」⇒ nil。
    func test记录不完整时返回nil() throws {
        let noPath = BookRecord(bookPath: "/progress/no-path/", title: "缺路径")
        noPath.lastReadChapterName = "第七章"
        noPath.lastReadOffset = 12
        let noName = BookRecord(bookPath: "/progress/no-name/", title: "缺章名")
        noName.lastReadChapterPath = "/progress/no-name/7.html"
        noName.lastReadOffset = 12
        let emptyName = BookRecord(bookPath: "/progress/empty-name/", title: "空章名")
        emptyName.lastReadChapterPath = "/progress/empty-name/7.html"
        emptyName.lastReadChapterName = ""
        context.insert(noPath)
        context.insert(noName)
        context.insert(emptyName)
        try context.save()

        XCTAssertNil(try ReadingProgressStoreLive.load(bookPath: noPath.bookPath, in: context))
        XCTAssertNil(try ReadingProgressStoreLive.load(bookPath: noName.bookPath, in: context))
        XCTAssertNil(try ReadingProgressStoreLive.load(bookPath: emptyName.bookPath, in: context))
    }

    func test书不存在时返回nil() throws {
        XCTAssertNil(try ReadingProgressStoreLive.load(bookPath: "/progress/missing/", in: context))
    }

    // MARK: - 写入：落盘的必须是传入的 offset

    /// 🔴 回归：live 实现曾把传入的 `offset` 丢掉、恒写 0 ⇒ 恢复位置永远回到章首。
    /// 用**另一个 `ModelContext`** 复读，证明值真的落盘了，而不只是内存里改了对象。
    func test写入落盘的是传入的offset() throws {
        let book = BookRecord(bookPath: "/progress/write/", title: "测试书")
        let chapter = ChapterRecord(
            bookPath: book.bookPath,
            number: 7,
            name: "第七章",
            path: "/progress/write/7.html"
        )
        context.insert(book)
        context.insert(chapter)
        try context.save()

        let readAt = Date(timeIntervalSince1970: 12345)
        try ReadingProgressStoreLive.markRead(
            chapterPath: chapter.path,
            offset: 137,
            date: readAt,
            in: context
        )

        let verifier = ModelContext(container)
        let stored = try verifier.fetch(FetchDescriptor<BookRecord>()).first
        XCTAssertEqual(stored?.lastReadOffset, 137)
        XCTAssertEqual(stored?.lastReadChapterPath, chapter.path)
        XCTAssertEqual(stored?.lastReadChapterName, "第七章")
        XCTAssertEqual(stored?.lastReadAt, readAt)
    }

    // MARK: - ReaderFeature：首次加载恢复位置

    /// 样本正文：10 个中文。
    private static let sampleText = "一二三四五六七八九十"

    /// 10 字正文（无章名前缀）→ 每页 5 字 → 2 页。
    private static let plainPages = [
        PageRange(location: 0, length: 5),
        PageRange(location: 5, length: 5),
    ]

    /// `"第七章\n\n" + 10 字` = 15 字 → 每页 5 字 → 3 页（页首 0 / 5 / 10）。
    private static let titledPages = [
        PageRange(location: 0, length: 5),
        PageRange(location: 5, length: 5),
        PageRange(location: 10, length: 5),
    ]

    /// 分页桩固定按每页 5 字切分：本组断言的是 `currentOffset`，需要确定的页边界。
    ///
    /// `progressRecorder` 只在断言「落盘偏移」的用例里传（见文件末尾的 extension）。
    private func makeReaderStore(
        text: String,
        initialOffset: Int,
        progressRecorder: ProgressOffsetRecorder? = nil
    ) -> TestStore<ReaderFeature.State, ReaderFeature.Action> {
        TestStore(
            initialState: ReaderFeature.State(
                chapterPath: "/1/1.html",
                initialOffset: initialOffset
            )
        ) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = { _ in text }
            $0.readingProgressStore.markRead = { _, offset, _ in
                guard let progressRecorder else { return }
                await progressRecorder.record(offset)
            }
            $0.chapterCacheStore.cacheCurrentAndFollowing = { _, _, _ in }
            $0.paginationService.paginate = { pageText, _ in
                readerTestPageRanges(of: pageText)
            }
        }
    }

    /// 首次加载样本正文并断言恢复结果（`initialOffset` 必须已被消费归零）。
    private func loadFirstChapter(
        into store: TestStore<ReaderFeature.State, ReaderFeature.Action>,
        chapterName: String = "",
        expectedPages: [PageRange],
        expectedOffset: Int
    ) async {
        await store.send(.loadChapterWithName("/1/1.html", chapterName)) {
            $0.chapterPath = "/1/1.html"
            $0.chapterName = chapterName
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded(Self.sampleText)) {
            $0.text = Self.sampleText
            $0.isLoading = false
            $0.pages = expectedPages
            $0.currentOffset = expectedOffset
            $0.initialOffset = 0
        }
    }

    func test首次加载恢复到指定偏移() async {
        let store = makeReaderStore(text: Self.sampleText, initialOffset: 3)

        await loadFirstChapter(into: store, expectedPages: Self.plainPages, expectedOffset: 3)
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 3)
        XCTAssertEqual(store.state.initialOffset, 0, "恢复一次后必须归零")
    }

    /// 🔴 换算：`initialOffset` 是落盘口径（**相对原始正文**），恢复时要加回章名前缀长度。
    /// 「第七章」前缀 5 ⇒ 落盘的 3 在 `displayText` 里是第 8 字。
    func test带章名前缀时恢复要加回前缀长度() async {
        let store = makeReaderStore(text: Self.sampleText, initialOffset: 3)

        await loadFirstChapter(
            into: store,
            chapterName: "第七章",
            expectedPages: Self.titledPages,
            expectedOffset: 8
        )
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 8)
        XCTAssertEqual(store.state.currentPageIndex, 1, "8 落在第 2 页 [5, 10)")
    }

    /// 🔴 回归护栏：`initialOffset == 0`（默认值 / 从未看过 / 已消费）⇒ **章首第一页**。
    ///
    /// 若「加回章名前缀长度」无条件执行，这里会变成 5（章名之后）——
    /// 既破坏「从未看过就第一章第一页」，也会让既有
    /// `ReaderFeatureTests.test章节名参与第一页分页` 与 `ReaderChapterAdvanceTests.loadFirst` 变红。
    func test无持久化位置时带章名也从章首开始() async {
        let store = makeReaderStore(text: Self.sampleText, initialOffset: 0)

        await loadFirstChapter(
            into: store,
            chapterName: "第七章",
            expectedPages: Self.titledPages,
            expectedOffset: 0
        )
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 0)
    }

    /// 🔴 往返：落盘口径 `progressOffset`（相对原始正文）→ `initialOffset` → 恢复回
    /// **同一个** `currentOffset`（相对 `displayText`）。
    ///
    /// 取 `X = 10`（`displayText` 的第 3 页页首）：它落盘成 5（原始正文第 5 字）。
    /// 恢复时**少加**前缀长度 5 就会落到 5 = 第 2 页页首 —— 正好暴露「差一整页」。
    func test往返恢复回同一位置() async {
        let chapterName = "第七章"
        var origin = ReaderFeature.State(
            chapterPath: "/1/1.html",
            chapterName: chapterName,
            text: Self.sampleText
        )
        origin.pages = Self.titledPages
        origin.currentOffset = 10

        XCTAssertEqual(origin.titlePrefixLength, 5, "前置条件：章名前缀 5 字")
        XCTAssertEqual(origin.progressOffset, 5, "落盘口径：相对原始正文")
        XCTAssertEqual(origin.currentPageIndex, 2, "前置条件：10 是第 3 页页首")

        let store = makeReaderStore(text: Self.sampleText, initialOffset: origin.progressOffset)
        await loadFirstChapter(
            into: store,
            chapterName: chapterName,
            expectedPages: Self.titledPages,
            expectedOffset: 10
        )
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 10, "必须回到原来的 displayText 坐标")
        XCTAssertEqual(store.state.currentPageIndex, 2, "并且仍在同一页（第 3 页页首）")
    }

    /// 换章（含从目录 `loadChapterWithName` 跳章）仍从章首开始：
    /// `initialOffset` 已被首次加载消费掉，不会再恢复。
    func test第二次加载不再恢复位置() async {
        let store = makeReaderStore(text: Self.sampleText, initialOffset: 3)
        await loadFirstChapter(into: store, expectedPages: Self.plainPages, expectedOffset: 3)

        await store.send(.loadChapterWithName("/1/2.html", "第二章")) {
            $0.chapterPath = "/1/2.html"
            $0.chapterName = "第二章"
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded(Self.sampleText)) {
            $0.text = Self.sampleText
            $0.isLoading = false
            // "第二章\n\n" + 10 字 = 15 字 → 3 页
            $0.pages = Self.titledPages
            $0.currentOffset = 0
        }
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 0)
    }

    /// 越界偏移：**先加前缀再夹**，仍夹到 `displayText.count - 1`（不崩、不越界）。
    func test偏移超出文本长度被夹到最后() async {
        let store = makeReaderStore(text: Self.sampleText, initialOffset: 9999)

        await loadFirstChapter(
            into: store,
            chapterName: "第七章",
            expectedPages: Self.titledPages,
            expectedOffset: 14
        )
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 14, "15 字 displayText 的最后一个字符偏移是 14")
    }

    /// 正文为空时夹到 0（`max(0, count - 1)` 不能变成负数）。
    func test正文为空时偏移夹到零() async {
        let store = makeReaderStore(text: "", initialOffset: 5)

        await store.send(.loadChapterWithName("/1/1.html", "")) {
            $0.chapterPath = "/1/1.html"
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded("")) {
            $0.text = ""
            $0.isLoading = false
            $0.pages = []
            $0.currentOffset = 0
            $0.initialOffset = 0
        }
        await store.finish()

        XCTAssertEqual(store.state.currentOffset, 0)
    }
}

// MARK: - 分页桩

/// 固定每页 5 字（与 `ReaderFeatureTests` 的「每页 5 字」口径一致）。
///
/// 放**文件级**而不是类的 `static`：`paginate` 的闭包类型是 `@Sendable`（非隔离），
/// 而 `@MainActor` 类上的 `static` 成员是 MainActor 隔离的，从闭包里调会报隔离错误
/// （既有先例：`ReaderFeatureTests` 的 `fakeWidthBudget` 同样是文件级函数）。
private let readerTestPageSize = 5

/// 确定性分页桩：按 `readerTestPageSize` 逐页切分 `displayText`（空文本 → 空数组）。
private func readerTestPageRanges(of displayText: String) -> [PageRange] {
    var ranges: [PageRange] = []
    var location = 0
    while location < displayText.count {
        let length = min(readerTestPageSize, displayText.count - location)
        ranges.append(PageRange(location: location, length: length))
        location += length
    }
    return ranges
}

// MARK: - contentLoaded 落盘的必须是恢复后的偏移（不能恒写 0）

/// 收 `markRead` 落盘 offset 的**跨线程安全**记录器。
///
/// `markRead` 是 `@Sendable` 闭包，要把值带出到测试线程就得走 actor
/// （不用 `@unchecked Sendable` 的自建盒子：那需要自己保证线程安全，得不偿失）。
private actor ProgressOffsetRecorder {
    private var offsets: [Int] = []

    func record(_ offset: Int) {
        offsets.append(offset)
    }

    /// 最近一次落盘的偏移；从未落盘 ⇒ `nil`（据此能区分「没写」与「写了 0」）。
    var lastOffset: Int? {
        offsets.last
    }
}

/// 新用例放 extension：`ReadingProgressTests` 的类型体贴近 `type_body_length`
/// warning 250（CI `--strict` 下 warning 即失败），而**声明在父类型大括号之外**的
/// extension 不计入该指标（先例：`ReaderFeature.State` 的派生值 extension）。
extension ReadingProgressTests {
    /// 🔴 回归：`contentLoaded` 里那句 `markRead(chapterPath, 0, ...)` 会把**刚恢复的位置**
    /// 当场抹成 0 ⇒ 打开任何一章都会丢掉该章已存的偏移，下次进来只能回到章首
    /// （owner 真机反馈「换了一本书以后，就只会回到看的章节首页，具体页数回不去」）。
    ///
    /// 带 `initialOffset = 3` + 章名「第七章」加载：`currentOffset` 恢复到 8，
    /// 落盘口径（`progressOffset`，**相对原始正文**）必须是 **3** —— 不是 0。
    func test加载后落盘的是恢复后的偏移而不是零() async {
        let recorder = ProgressOffsetRecorder()
        let store = makeReaderStore(
            text: Self.sampleText,
            initialOffset: 3,
            progressRecorder: recorder
        )

        await loadFirstChapter(
            into: store,
            chapterName: "第七章",
            expectedPages: Self.titledPages,
            expectedOffset: 8
        )
        await store.finish()

        let recorded = await recorder.lastOffset
        XCTAssertEqual(recorded, 3, "落盘必须是恢复后的偏移（相对原始正文），不能恒写 0")
    }

    /// 🔴 往返（一次锁住「恢复 + 不被抹掉」）：加载 → 断言落盘偏移 == 期望 →
    /// 用**落盘的那个值**再次加载 ⇒ `currentOffset` 回到同一位置。
    ///
    /// 取 `initialOffset = 5`（`displayText` 的第 3 页页首，见 `titledPages`）：
    /// 落盘必须还是 5；拿它再开一次必须回到 10（第 3 页页首）而不是章首。
    func test落盘偏移往返回到同一位置() async throws {
        let recorder = ProgressOffsetRecorder()
        let store = makeReaderStore(
            text: Self.sampleText,
            initialOffset: 5,
            progressRecorder: recorder
        )
        await loadFirstChapter(
            into: store,
            chapterName: "第七章",
            expectedPages: Self.titledPages,
            expectedOffset: 10
        )
        await store.finish()

        let recorded = await recorder.lastOffset
        let persisted = try XCTUnwrap(recorded, "加载完成后必须落盘一次进度")

        // 用落盘值再开一次（模拟「换了一本书又回来」）：必须回到同一个位置。
        let reopened = makeReaderStore(text: Self.sampleText, initialOffset: persisted)
        await loadFirstChapter(
            into: reopened,
            chapterName: "第七章",
            expectedPages: Self.titledPages,
            expectedOffset: 10
        )
        await reopened.finish()

        XCTAssertEqual(persisted, 5, "落盘口径：displayText 的 10 是原始正文的 5")
        XCTAssertEqual(reopened.state.currentOffset, 10, "必须回到原来的 displayText 坐标")
        XCTAssertEqual(reopened.state.currentPageIndex, 2, "并且仍在同一页（第 3 页页首）")
    }
}
