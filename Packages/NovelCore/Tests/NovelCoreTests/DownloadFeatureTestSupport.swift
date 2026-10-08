import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 下载任务测试使用的固定时间戳，避免断言随 `Date()` 漂移。
let downloadFixtureDate = Date(timeIntervalSince1970: 1_700_000_000)

/// 下载队列的内存实现，严格保持 Live 版本的「返回完整队列」契约。
actor InMemoryDownloadQueueStore {
    private var tasksByID: [String: DownloadTaskSnapshot]
    private var orderedIDs: [String]

    init(initialTasks: [DownloadTaskSnapshot] = []) {
        tasksByID = Dictionary(uniqueKeysWithValues: initialTasks.map { ($0.id, $0) })
        orderedIDs = initialTasks.map(\.id)
    }

    nonisolated func dependency() -> DownloadQueueStore {
        DownloadQueueStore(
            load: { try await self.load() },
            enqueue: { try await self.enqueue($0) },
            mutate: { try await self.mutate($0, mutation: $1) },
            complete: { try await self.complete(taskID: $0, text: $1) },
            remove: { try await self.remove($0) }
        )
    }

    private func load() throws -> [DownloadTaskSnapshot] {
        orderedSnapshots()
    }

    private func enqueue(
        _ requests: [DownloadChapterRequest]
    ) throws -> [DownloadTaskSnapshot] {
        for request in requests {
            let id = DownloadTask.makeId(
                bookPath: request.bookPath,
                chapterPath: request.chapterPath
            )
            if var existing = tasksByID[id] {
                guard existing.state != .done else { continue }
                existing.state = .queued
                existing.lastError = nil
                existing.blockedByGuard = false
                existing.finishedAt = nil
                tasksByID[id] = existing
            } else {
                tasksByID[id] = DownloadTaskSnapshot(
                    id: id,
                    bookPath: request.bookPath,
                    bookTitle: request.bookTitle,
                    chapterPath: request.chapterPath,
                    chapterName: request.chapterName,
                    chapterNumber: request.chapterNumber,
                    state: .queued,
                    attempts: 0,
                    lastError: nil,
                    blockedByGuard: false,
                    createdAt: downloadFixtureDate,
                    finishedAt: nil
                )
                orderedIDs.append(id)
            }
        }
        return orderedSnapshots()
    }

    private func mutate(
        _ ids: [String],
        mutation: DownloadTaskMutation
    ) throws -> [DownloadTaskSnapshot] {
        for id in ids {
            guard var task = tasksByID[id] else { continue }
            switch mutation {
            case .markDownloading:
                task.state = .downloading
                task.finishedAt = nil
            case .pauseByUser:
                task.state = .paused
                task.lastError = nil
                task.blockedByGuard = false
            case let .pauseBlocked(message):
                task.state = .paused
                task.lastError = message
                task.blockedByGuard = true
            case let .markFailed(message):
                task.state = .failed
                task.attempts += 1
                task.lastError = message
                task.blockedByGuard = false
            case .requeue:
                task.state = .queued
                task.lastError = nil
                task.blockedByGuard = false
                task.finishedAt = nil
            }
            tasksByID[id] = task
        }
        return orderedSnapshots()
    }

    private func complete(
        taskID: String,
        text _: String
    ) throws -> DownloadTaskSnapshot {
        guard var task = tasksByID[taskID] else {
            throw DownloadQueueStoreError.taskNotFound
        }
        task.state = .done
        task.lastError = nil
        task.blockedByGuard = false
        task.finishedAt = downloadFixtureDate
        tasksByID[taskID] = task
        return task
    }

    private func remove(_ ids: [String]) throws {
        for id in ids {
            tasksByID.removeValue(forKey: id)
            orderedIDs.removeAll { $0 == id }
        }
    }

    func snapshot(id: String) -> DownloadTaskSnapshot? {
        tasksByID[id]
    }

    private func orderedSnapshots() -> [DownloadTaskSnapshot] {
        orderedIDs.compactMap { tasksByID[$0] }
    }
}

/// 可控制何时返回正文的下载器，用于稳定制造「请求仍在途」的窗口。
actor DownloadGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<String, Error>?

    func download(_: String) async throws -> String {
        started = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }

        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func release(_ text: String) {
        resultContinuation?.resume(returning: text)
        resultContinuation = nil
    }
}

/// 下载 Feature 测试的公共夹具。
@MainActor
class DownloadFeatureTestCase: XCTestCase {
    static let bookPath = "/1/1/"
    static let bookTitle = "示例书"
    static let chapterPath = "/1/1/1.html"
    static let chapterID = DownloadTask.makeId(
        bookPath: bookPath,
        chapterPath: chapterPath
    )

    func makeRequest() -> DownloadChapterRequest {
        DownloadChapterRequest(
            bookPath: Self.bookPath,
            bookTitle: Self.bookTitle,
            chapterPath: Self.chapterPath,
            chapterName: "第一章",
            chapterNumber: 1
        )
    }

    func snapshot(
        state: DownloadState = .queued,
        attempts: Int = 0,
        lastError: String? = nil,
        blockedByGuard: Bool = false
    ) -> DownloadTaskSnapshot {
        DownloadTaskSnapshot(
            id: Self.chapterID,
            bookPath: Self.bookPath,
            bookTitle: Self.bookTitle,
            chapterPath: Self.chapterPath,
            chapterName: "第一章",
            chapterNumber: 1,
            state: state,
            attempts: attempts,
            lastError: lastError,
            blockedByGuard: blockedByGuard,
            createdAt: downloadFixtureDate,
            finishedAt: state == .done ? downloadFixtureDate : nil
        )
    }

    func makeStore(
        initialState: DownloadFeature.State = DownloadFeature.State(),
        queue: InMemoryDownloadQueueStore = InMemoryDownloadQueueStore(),
        gate: DownloadGate = DownloadGate()
    ) -> TestStore<DownloadFeature.State, DownloadFeature.Action> {
        TestStore(initialState: initialState) {
            DownloadFeature()
        } withDependencies: {
            $0.downloadQueueStore = queue.dependency()
            $0.chapterDownloader.download = { chapterPath in
                try await gate.download(chapterPath)
            }
        }
    }
}
