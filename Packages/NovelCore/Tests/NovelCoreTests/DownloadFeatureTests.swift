import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

/// 下载队列正常路径与控制动作测试。
@MainActor
final class DownloadFeatureTests: DownloadFeatureTestCase {
    func test入队后下载并完成() async {
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

        let downloading = await queue.snapshot(id: Self.chapterID)
        XCTAssertEqual(downloading?.state, .downloading)

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

        let persisted = await queue.snapshot(id: Self.chapterID)
        XCTAssertEqual(persisted?.state, .done)
        XCTAssertEqual(store.state.finishedCount, 1)
    }

    func test未放行网络时不启动下载() async {
        let queue = InMemoryDownloadQueueStore()
        let gate = DownloadGate()
        let store = makeStore(
            initialState: DownloadFeature.State(allowsCellular: false, speed: .fast),
            queue: queue,
            gate: gate
        )

        await store.send(.enqueue([makeRequest()]))
        let queued = snapshot(state: .queued)
        await store.receive(.enqueued([queued])) {
            $0.tasks = [queued]
        }

        let started = await gate.hasStarted()
        XCTAssertFalse(started)
        XCTAssertFalse(store.state.isDownloading)
        await store.finish()
    }

    func test全局暂停与继续() async {
        let queued = snapshot(state: .queued)
        let paused = snapshot(state: .paused)
        let queue = InMemoryDownloadQueueStore(initialTasks: [queued])
        let store = makeStore(
            initialState: DownloadFeature.State(tasks: [queued], allowsCellular: false),
            queue: queue
        )

        await store.send(.pauseAll) {
            $0.isPaused = true
            $0.notice = "已暂停全部下载。"
            $0.tasks = [paused]
        }
        await store.receive(.persisted([paused]))

        await store.send(.resumeAll) {
            $0.isPaused = false
            $0.notice = nil
        }
        await store.receive(.persisted([queued])) {
            $0.tasks = [queued]
        }
        await store.finish()
    }

    func test普通失败标记为失败() async {
        let downloading = snapshot(state: .downloading)
        let failed = snapshot(
            state: .failed,
            attempts: 1,
            lastError: "网络抖动"
        )
        let queue = InMemoryDownloadQueueStore(initialTasks: [downloading])
        let store = makeStore(
            initialState: DownloadFeature.State(
                tasks: [downloading],
                allowsCellular: true,
                speed: .fast,
                isDownloading: true
            ),
            queue: queue
        )
        let failure = DownloadFailure(source: .other, message: "网络抖动")

        await store.send(.downloaderFailed(Self.chapterID, failure)) {
            $0.isDownloading = false
            $0.notice = "下载失败：网络抖动"
        }
        await store.receive(.persisted([failed])) {
            $0.tasks = [failed]
        }
        await store.finish()
    }

    func test遇盾自动暂停且不计重试() async {
        let downloading = snapshot(state: .downloading)
        let queue = InMemoryDownloadQueueStore(initialTasks: [downloading])
        let store = makeStore(
            initialState: DownloadFeature.State(
                tasks: [downloading],
                allowsCellular: true,
                speed: .fast,
                isDownloading: true
            ),
            queue: queue
        )
        let failure = classifyDownloadFailure(NetworkError.guarded)
        let blocked = snapshot(
            state: .paused,
            lastError: failure.message,
            blockedByGuard: true
        )

        await store.send(.downloaderFailed(Self.chapterID, failure)) {
            $0.isDownloading = false
            $0.isPaused = true
            $0.notice = "需要人机验证，已暂停下载。"
        }
        await store.receive(.persisted([blocked])) {
            $0.tasks = [blocked]
        }
        await store.finish()

        XCTAssertEqual(blocked.attempts, 0)
        XCTAssertFalse(NetworkError.guarded.shouldRetry)
    }

    func test403自动暂停且不计重试() async {
        let downloading = snapshot(state: .downloading)
        let queue = InMemoryDownloadQueueStore(initialTasks: [downloading])
        let store = makeStore(
            initialState: DownloadFeature.State(
                tasks: [downloading],
                allowsCellular: true,
                speed: .fast,
                isDownloading: true
            ),
            queue: queue
        )
        let failure = classifyDownloadFailure(NetworkError.httpStatus(403))
        let blocked = snapshot(
            state: .paused,
            lastError: failure.message,
            blockedByGuard: true
        )

        await store.send(.downloaderFailed(Self.chapterID, failure)) {
            $0.isDownloading = false
            $0.isPaused = true
            $0.notice = "服务器拒绝了请求，已暂停下载。请稍后再继续。"
        }
        await store.receive(.persisted([blocked])) {
            $0.tasks = [blocked]
        }
        await store.finish()

        XCTAssertEqual(blocked.attempts, 0)
        XCTAssertFalse(NetworkError.httpStatus(403).shouldRetry)
    }

    func test只重试失败任务() async {
        let failed = snapshot(
            state: .failed,
            attempts: 1,
            lastError: "超时"
        )
        let paused = makePausedTask()
        let requeued = snapshot(state: .queued, attempts: 1)
        let queue = InMemoryDownloadQueueStore(initialTasks: [failed, paused])
        let store = makeStore(
            initialState: DownloadFeature.State(
                tasks: [failed, paused],
                allowsCellular: false
            ),
            queue: queue
        )

        await store.send(.retryFailed)
        await store.receive(.persisted([requeued, paused])) {
            $0.tasks = [requeued, paused]
        }
        await store.finish()
    }

    private func makePausedTask() -> DownloadTaskSnapshot {
        DownloadTaskSnapshot(
            id: "/2/2/#/2/2/1.html",
            bookPath: "/2/2/",
            bookTitle: "另一本书",
            chapterPath: "/2/2/1.html",
            chapterName: "第一章",
            chapterNumber: 1,
            state: .paused,
            attempts: 0,
            lastError: nil,
            blockedByGuard: false,
            createdAt: downloadFixtureDate,
            finishedAt: nil
        )
    }
}
