import ComposableArchitecture
@testable import NovelCore
import XCTest

/// 下载队列的重启恢复与在途结果竞态测试。
@MainActor
final class DownloadFeatureRaceTests: DownloadFeatureTestCase {
    func test重启把下载中恢复为排队() async {
        let stale = snapshot(state: .downloading)
        let queued = snapshot(state: .queued)
        let queue = InMemoryDownloadQueueStore(initialTasks: [stale])
        let store = makeStore(
            initialState: DownloadFeature.State(allowsCellular: false),
            queue: queue
        )

        await store.send(.reload)
        await store.receive(.loaded([stale])) {
            $0.tasks = [queued]
        }
        await store.finish()

        XCTAssertEqual(store.state.tasks.first?.state, .queued)
        XCTAssertFalse(store.state.isDownloading)
    }

    func test暂停单本丢弃在途结果() async {
        let queue = InMemoryDownloadQueueStore()
        let gate = DownloadGate()
        let store = makeStore(
            initialState: DownloadFeature.State(allowsCellular: true, speed: .fast),
            queue: queue,
            gate: gate
        )

        await store.send(.enqueue([makeRequest()]))
        await store.receive(.enqueued([snapshot(state: .queued)])) {
            $0.tasks = [self.snapshot(state: .downloading)]
            $0.isDownloading = true
        }
        await gate.waitUntilStarted()

        let paused = snapshot(state: .paused)
        await store.send(.pauseBook(Self.bookPath)) {
            $0.tasks = [paused]
            $0.notice = "已暂停《示例书》的下载。"
        }
        await store.receive(.persisted([paused]))

        await gate.release("正文")
        await store.receive(.downloaderSucceeded(Self.chapterID, "正文")) {
            $0.isDownloading = false
        }
        await store.finish()

        let persisted = await queue.snapshot(id: Self.chapterID)
        XCTAssertEqual(persisted?.state, .paused)
        XCTAssertEqual(store.state.finishedCount, 0)
    }

    func test取消单本丢弃在途结果() async {
        let queue = InMemoryDownloadQueueStore()
        let gate = DownloadGate()
        let store = makeStore(
            initialState: DownloadFeature.State(allowsCellular: true, speed: .fast),
            queue: queue,
            gate: gate
        )

        await store.send(.enqueue([makeRequest()]))
        await store.receive(.enqueued([snapshot(state: .queued)])) {
            $0.tasks = [self.snapshot(state: .downloading)]
            $0.isDownloading = true
        }
        await gate.waitUntilStarted()

        await store.send(.cancelBook(Self.bookPath)) {
            $0.tasks = []
            $0.notice = "已取消《示例书》的下载。"
        }
        await store.receive(.reload)
        await store.receive(.loaded([]))

        await gate.release("正文")
        await store.receive(.downloaderSucceeded(Self.chapterID, "正文")) {
            $0.isDownloading = false
        }
        await store.finish()

        let persisted = await queue.snapshot(id: Self.chapterID)
        XCTAssertNil(persisted)
        XCTAssertTrue(store.state.tasks.isEmpty)
    }
}
