import ComposableArchitecture
@testable import NovelCore
import XCTest

/// 书卡选择模式与「删除下载」的测试（U10）。
///
/// 单独一个测试文件而不是塞进 `DownloadFeatureTests`：那个类的 `type_body_length`
/// 已经贴着 250 行，再加就超（本机 `_lint_approx.ps1` 会先报出来）。
@MainActor
final class DownloadSelectionTests: DownloadFeatureTestCase {
    /// 「删除下载」= 取消本书下载 + 删已下载正文；**不**走队列级 `.retryFailed`，也不走淘汰器。
    func test删除下载会取消任务并删已下载正文() async {
        let done = snapshot(state: .done)
        let queue = InMemoryDownloadQueueStore(initialTasks: [done])
        let store = makeStore(
            initialState: DownloadFeature.State(tasks: [done], allowsCellular: false),
            queue: queue
        )

        await store.send(.deleteDownloads([Self.bookPath])) {
            $0.tasks = []
            $0.notice = "已删除《示例书》的下载，已下载的正文已清除。"
        }
        await store.receive(.reload)
        await store.receive(.loaded([]))
        await store.finish()

        let remaining = await queue.snapshot(id: Self.chapterID)
        XCTAssertNil(remaining)
        let removedBooks = await queue.removedDownloadedBookPaths()
        XCTAssertEqual(removedBooks, [Self.bookPath])
    }

    /// 批量「重试失败」按**书**过滤：只重排选中书里失败的任务。
    func test批量重试失败只作用于选中的书() async {
        let mine = snapshot(state: .failed, attempts: 1, lastError: "超时")
        let other = makeOtherBookFailedTask()
        let requeued = snapshot(state: .queued, attempts: 1)
        let queue = InMemoryDownloadQueueStore(initialTasks: [mine, other])
        let store = makeStore(
            initialState: DownloadFeature.State(
                tasks: [mine, other],
                allowsCellular: false,
                isSelecting: true,
                selectedBookPaths: [Self.bookPath]
            ),
            queue: queue
        )

        await store.send(.retryFailedSelectedBooks)
        await store.receive(.persisted([requeued, other])) {
            $0.tasks = [requeued, other]
        }
        await store.finish()
    }

    /// 「全选」的判据是**书**（`bookPath`），不是章节。
    func test全选判据是书不是章节() {
        let first = snapshot(state: .queued)
        let second = DownloadTaskSnapshot(
            id: DownloadTask.makeId(bookPath: Self.bookPath, chapterPath: "/1/1/2.html"),
            bookPath: Self.bookPath,
            bookTitle: Self.bookTitle,
            chapterPath: "/1/1/2.html",
            chapterName: "第二章",
            chapterNumber: 2,
            state: .queued,
            attempts: 0,
            lastError: nil,
            blockedByGuard: false,
            createdAt: downloadFixtureDate,
            finishedAt: nil
        )
        var state = DownloadFeature.State(tasks: [first, second], allowsCellular: false)

        XCTAssertEqual(state.bookPaths, [Self.bookPath])

        state.toggleSelectAllBooks()
        XCTAssertEqual(state.selectedBookPaths, [Self.bookPath])
        XCTAssertTrue(state.areAllBooksSelected)

        state.toggleSelectAllBooks()
        XCTAssertTrue(state.selectedBookPaths.isEmpty)
        XCTAssertFalse(state.areAllBooksSelected)
    }

    private func makeOtherBookFailedTask() -> DownloadTaskSnapshot {
        DownloadTaskSnapshot(
            id: DownloadTask.makeId(bookPath: "/2/2/", chapterPath: "/2/2/1.html"),
            bookPath: "/2/2/",
            bookTitle: "另一本书",
            chapterPath: "/2/2/1.html",
            chapterName: "第一章",
            chapterNumber: 1,
            state: .failed,
            attempts: 1,
            lastError: "超时",
            blockedByGuard: false,
            createdAt: downloadFixtureDate,
            finishedAt: nil
        )
    }
}
