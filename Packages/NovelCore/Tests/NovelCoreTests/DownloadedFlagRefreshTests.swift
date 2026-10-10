import ComposableArchitecture
@testable import NovelCore
import XCTest

/// 下载**进行中**时，详情页「已下载」标记的就地刷新。
///
/// 守两条边界：
/// 1. 这个 action 只做**纯内存**打标 —— 不重读 `chapterListLoader`，
///    也不新增第二套「已下载」判据（唯一真相仍是 `ChapterRecord.source == .downloaded`）；
/// 2. 信号来自 `DownloadFeature.State.completedChapterPaths(forBook:)` 这个纯内存派生值，
///    它的稳定性取决于「完成的任务会留在队列里」（见文件末尾的派生值测试）。
@MainActor
final class BookDetailDownloadedFlagTests: XCTestCase {
    private static let bookPath = "/1/"
    private static let fallback = BookDetail(bookPath: bookPath, title: "搜索结果")

    private static func makeChapter(number: Int, isDownloaded: Bool = false) -> ChapterItem {
        ChapterItem(
            number: number,
            name: "第 \(number) 章",
            path: "/1/\(number).html",
            hasLocalText: isDownloaded,
            isDownloaded: isDownloaded
        )
    }

    private static func makeState(_ chapters: [ChapterItem]) -> BookDetailFeature.State {
        var state = BookDetailFeature.State(fallback: fallback)
        state.chapters = chapters
        return state
    }

    /// 只标记给定路径的章节：其余章节的标记一个字都不动。
    func test下载完成只标记给定路径的章节() async {
        let store = TestStore(initialState: Self.makeState([
            Self.makeChapter(number: 1),
            Self.makeChapter(number: 2),
            Self.makeChapter(number: 3),
        ])) {
            BookDetailFeature()
        }

        await store.send(.chaptersDownloaded(["/1/2.html"])) {
            $0.chapters[1] = Self.makeChapter(number: 2, isDownloaded: true)
        }
        // 连带把「本地有正文」置位：正文在写 `source` 之前就已落盘，两者不该互相矛盾。
        XCTAssertTrue(store.state.chapters[1].hasLocalText)
        XCTAssertEqual(store.state.downloadedChapterCount, 1)
        XCTAssertEqual(store.state.downloadableChapterCount, 2)
        await store.finish()
    }

    /// 幂等：同一个路径再来一次，状态**逐字相等**（reducer 跳过已标记的章节，不做等值写入）。
    func test重复通知同一章节不产生状态差异() async {
        let store = TestStore(initialState: Self.makeState([Self.makeChapter(number: 2)])) {
            BookDetailFeature()
        }

        await store.send(.chaptersDownloaded(["/1/2.html"])) {
            $0.chapters[0] = Self.makeChapter(number: 2, isDownloaded: true)
        }
        // 第二次不带尾随闭包 == 断言状态零差异。
        await store.send(.chaptersDownloaded(["/1/2.html"]))
        await store.finish()
    }

    /// 不在当前目录里的路径被安全忽略：别的书的路径、已消失的章节都不会新建条目。
    func test不在目录里的完成路径被安全忽略() async {
        let store = TestStore(initialState: Self.makeState([
            Self.makeChapter(number: 1),
            Self.makeChapter(number: 2),
        ])) {
            BookDetailFeature()
        }

        await store.send(.chaptersDownloaded(["/9/9/9.html", "/1/2.html", "/1/999.html"])) {
            $0.chapters[1] = Self.makeChapter(number: 2, isDownloaded: true)
        }
        XCTAssertEqual(store.state.chapters.count, 2)
        XCTAssertEqual(store.state.downloadedChapterCount, 1)
        await store.finish()
    }

    /// 空列表是零操作（App 层已挡了一层，reducer 也不再遍历目录）。
    func test空完成列表是零操作() async {
        let store = TestStore(initialState: Self.makeState([Self.makeChapter(number: 1)])) {
            BookDetailFeature()
        }

        await store.send(.chaptersDownloaded([]))
        await store.finish()
    }
}

/// 「已完成章节」信号（`completedChapterPaths(forBook:)`）的派生行为与生命周期的测试。
@MainActor
final class DownloadFeatureCompletedChapterPathsTests: DownloadFeatureTestCase {
    /// 只收 `.done`：排队 / 下载中 / 暂停 / 失败都不算已完成。
    func test已完成章节只收已完成的任务() {
        var state = DownloadFeature.State(tasks: [
            snapshot(state: .queued),
            makeSnapshot(bookPath: "/2/2/", chapterPath: "/2/2/1.html", state: .downloading),
            makeSnapshot(bookPath: "/2/2/", chapterPath: "/2/2/2.html", state: .paused),
            makeSnapshot(bookPath: "/2/2/", chapterPath: "/2/2/3.html", state: .failed),
        ])

        XCTAssertTrue(state.completedChapterPaths(forBook: "/2/2/").isEmpty)

        state.tasks.append(makeSnapshot(bookPath: "/2/2/", chapterPath: "/2/2/4.html", state: .done))
        XCTAssertEqual(state.completedChapterPaths(forBook: "/2/2/"), ["/2/2/4.html"])
    }

    /// 本书的过滤只比 `DownloadTaskSnapshot.bookPath` 字段，不拼不拆
    /// `bookPath#chapterPath` 复合键 —— 所以别的书（含书路径互为前缀的书）的完成项，
    /// 以及「两本书里 chapterPath 恰好同名」这种极端情形，都不会串成本书的完成事件。
    func test已完成章节不会串到其它书上() {
        let state = DownloadFeature.State(tasks: [
            makeSnapshot(bookPath: "/1/1/", chapterPath: "/1/1/1.html", state: .done),
            makeSnapshot(bookPath: "/1/1/", chapterPath: "/1/1/2.html", state: .downloading),
            makeSnapshot(bookPath: "/1/11/", chapterPath: "/1/11/1.html", state: .done),
            // 极端情形：两本书的 chapterPath 一模一样，只有 bookPath 不同。
            makeSnapshot(bookPath: "/1/11/", chapterPath: "/1/1/1.html", state: .done),
        ])

        XCTAssertEqual(state.completedChapterPaths(forBook: "/1/1/"), ["/1/1/1.html"])
        XCTAssertEqual(state.completedChapterPaths(forBook: "/1/11/"), ["/1/1/1.html", "/1/11/1.html"])
        XCTAssertTrue(state.completedChapterPaths(forBook: "/2/2/").isEmpty)
    }

    /// 真实行为：`DownloadQueueStoreLive.complete(taskID:text:)` 只把任务 `markDone()`，
    /// **不**把它移出队列。所以一章下完后它仍留在 `state.tasks` 里 ——
    /// 详情页的观察者能在「刚完成」那一刻拿到这个信号，不必等下一次 `onAppear`。
    func test下载完成后已完成章节仍在信号里() async {
        let queue = InMemoryDownloadQueueStore()
        let gate = DownloadGate()
        let store = makeStore(
            initialState: DownloadFeature.State(
                allowsCellular: true,
                speed: .fast,
                networkKind: .wifi
            ),
            queue: queue,
            gate: gate
        )

        await store.send(.enqueue([makeRequest()]))
        // 完成之前：队列里只有排队中的那一项，信号为空。
        await store.receive(.enqueued([snapshot(state: .queued)])) {
            $0.tasks = [self.snapshot(state: .downloading)]
            $0.isDownloading = true
        }
        XCTAssertTrue(store.state.completedChapterPaths(forBook: Self.bookPath).isEmpty)
        await gate.waitUntilStarted()
        await gate.release("正文")
        await store.receive(.downloaderSucceeded(Self.chapterID, "正文")) {
            $0.isDownloading = false
        }
        await store.receive(.reload)

        let done = snapshot(state: .done)
        await store.receive(.loaded([done])) {
            $0.tasks = [done]
        }
        await store.finish()

        XCTAssertEqual(store.state.completedChapterPaths(forBook: Self.bookPath), [Self.chapterPath])
    }

    /// 唯一会把任务移出队列的是 `cancelBook`（→ `DownloadQueueStoreLive.remove`）：
    /// 取消整本后信号随之消失。详情页的就地标记是**本会话窗口内**的加速，
    /// 不是第二套「已下载」判据 —— 真相仍在 `ChapterRecord.source`。
    func test取消整本后已完成章节信号消失() async {
        let done = snapshot(state: .done)
        let queue = InMemoryDownloadQueueStore(initialTasks: [done])
        let store = makeStore(
            initialState: DownloadFeature.State(tasks: [done], allowsCellular: false),
            queue: queue
        )
        XCTAssertEqual(store.state.completedChapterPaths(forBook: Self.bookPath), [Self.chapterPath])

        await store.send(.cancelBook(Self.bookPath)) {
            $0.notice = "已取消《\(Self.bookTitle)》的下载。"
            $0.tasks = []
        }
        await store.receive(.reload)
        await store.receive(.loaded([])) {
            $0.tasks = []
        }
        await store.finish()

        XCTAssertTrue(store.state.completedChapterPaths(forBook: Self.bookPath).isEmpty)
    }

    private func makeSnapshot(
        bookPath: String,
        chapterPath: String,
        state: DownloadState
    ) -> DownloadTaskSnapshot {
        DownloadTaskSnapshot(
            id: DownloadTask.makeId(bookPath: bookPath, chapterPath: chapterPath),
            bookPath: bookPath,
            bookTitle: "示例书",
            chapterPath: chapterPath,
            chapterName: "第一章",
            chapterNumber: 1,
            state: state,
            attempts: 0,
            lastError: nil,
            blockedByGuard: false,
            createdAt: downloadFixtureDate,
            finishedAt: state == .done ? downloadFixtureDate : nil
        )
    }
}
