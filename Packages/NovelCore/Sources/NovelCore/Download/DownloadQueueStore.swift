import Dependencies
import Foundation
import SwiftData

/// 对持久化任务的状态变更。
enum DownloadTaskMutation: Equatable, Sendable {
    case markDownloading
    case pauseByUser
    case pauseBlocked(String)
    case markFailed(String)
    case requeue
}

/// 下载队列存储依赖。
///
/// reducer 不直接碰 SwiftData；这里把「持久化队列」和「正文落盘」收在同一层，
/// 测试可以完全替换为内存桩。
struct DownloadQueueStore: Sendable {
    var load: @Sendable () async throws -> [DownloadTaskSnapshot]
    var enqueue: @Sendable ([DownloadChapterRequest]) async throws -> [DownloadTaskSnapshot]
    var mutate: @Sendable ([String], DownloadTaskMutation) async throws -> [DownloadTaskSnapshot]
    var complete: @Sendable (String, String) async throws -> DownloadTaskSnapshot
    var remove: @Sendable ([String]) async throws -> Void
}

extension DependencyValues {
    var downloadQueueStore: DownloadQueueStore {
        get { self[DownloadQueueStoreKey.self] }
        set { self[DownloadQueueStoreKey.self] = newValue }
    }

    private enum DownloadQueueStoreKey: DependencyKey {
        static let liveValue = DownloadQueueStore(
            load: { try await DownloadQueueStoreLive.load() },
            enqueue: { try await DownloadQueueStoreLive.enqueue($0) },
            mutate: { try await DownloadQueueStoreLive.mutate($0, mutation: $1) },
            complete: { try await DownloadQueueStoreLive.complete(taskID: $0, text: $1) },
            remove: { try await DownloadQueueStoreLive.remove($0) }
        )

        static let testValue = DownloadQueueStore(
            load: { [] },
            enqueue: { requests in
                requests.map {
                    DownloadTaskSnapshot(
                        id: DownloadTask.makeId(bookPath: $0.bookPath, chapterPath: $0.chapterPath),
                        bookPath: $0.bookPath,
                        bookTitle: $0.bookTitle,
                        chapterPath: $0.chapterPath,
                        chapterName: $0.chapterName,
                        chapterNumber: $0.chapterNumber,
                        state: .queued,
                        attempts: 0,
                        lastError: nil,
                        blockedByGuard: false,
                        createdAt: Date(),
                        finishedAt: nil
                    )
                }
            },
            mutate: { ids, _ in ids.map { makePlaceholderSnapshot(id: $0) } },
            complete: { id, _ in makePlaceholderSnapshot(id: id, state: .done) },
            remove: { _ in }
        )
    }
}

private func makePlaceholderSnapshot(
    id: String,
    state: DownloadState = .queued
) -> DownloadTaskSnapshot {
    DownloadTaskSnapshot(
        id: id,
        bookPath: "",
        bookTitle: "",
        chapterPath: "",
        chapterName: "",
        chapterNumber: 0,
        state: state,
        attempts: 0,
        lastError: nil,
        blockedByGuard: false,
        createdAt: Date(),
        finishedAt: nil
    )
}

enum DownloadQueueStoreError: LocalizedError {
    case taskNotFound

    var errorDescription: String? {
        switch self {
        case .taskNotFound:
            "下载任务不存在。"
        }
    }
}

@MainActor
enum DownloadQueueStoreLive {
    static func load() throws -> [DownloadTaskSnapshot] {
        let context = try ModelContext(NovelStore.makeContainer())
        return try snapshots(from: fetchTasks(in: context))
    }

    static func enqueue(_ requests: [DownloadChapterRequest]) throws -> [DownloadTaskSnapshot] {
        let context = try ModelContext(NovelStore.makeContainer())
        let tasks = try fetchTasks(in: context)
        var tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        for request in requests {
            let id = DownloadTask.makeId(
                bookPath: request.bookPath,
                chapterPath: request.chapterPath
            )
            if let existing = tasksByID[id] {
                // 已完成的章节不重复入队；失败/暂停的章节重新入队，
                // 这样「断点续传」不需要用户重新点一遍。
                if existing.state != .done {
                    existing.requeue()
                }
            } else {
                let task = DownloadTask(
                    bookPath: request.bookPath,
                    bookTitle: request.bookTitle,
                    chapterPath: request.chapterPath,
                    chapterName: request.chapterName,
                    chapterNumber: request.chapterNumber
                )
                context.insert(task)
                tasksByID[id] = task
            }
        }

        try context.save()
        return try snapshots(from: fetchTasks(in: context))
    }

    static func mutate(
        _ ids: [String],
        mutation: DownloadTaskMutation
    ) throws -> [DownloadTaskSnapshot] {
        guard !ids.isEmpty else { return [] }
        let context = try ModelContext(NovelStore.makeContainer())
        let selectedIDs = Set(ids)
        let tasks = try fetchTasks(in: context).filter { selectedIDs.contains($0.id) }

        for task in tasks {
            apply(mutation, to: task)
        }
        try context.save()
        // 返回**完整队列**，而不是只返回被选中的项：
        // reducer 的 `.persisted` 用它整体替换 `state.tasks`，只给局部会让其余任务凭空消失。
        return try snapshots(from: fetchTasks(in: context))
    }

    static func complete(taskID: String, text: String) throws -> DownloadTaskSnapshot {
        let context = try ModelContext(NovelStore.makeContainer())
        guard let task = try fetchTasks(in: context).first(where: { $0.id == taskID }) else {
            throw DownloadQueueStoreError.taskNotFound
        }

        let fileName = try NovelStore.saveChapterText(
            text,
            bookPath: task.bookPath,
            number: task.chapterNumber
        )
        let chapter = try fetchChapter(
            bookPath: task.bookPath,
            number: task.chapterNumber,
            in: context
        )
        if let chapter {
            chapter.source = .downloaded
            chapter.localFileName = fileName
            chapter.savedAt = Date()
        } else {
            context.insert(ChapterRecord(
                bookPath: task.bookPath,
                number: task.chapterNumber,
                name: task.chapterName,
                path: task.chapterPath,
                source: .downloaded,
                localFileName: fileName
            ))
        }

        task.markDone()
        try context.save()
        return DownloadTaskSnapshot(task: task)
    }

    static func remove(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let context = try ModelContext(NovelStore.makeContainer())
        let selectedIDs = Set(ids)
        for task in try fetchTasks(in: context) where selectedIDs.contains(task.id) {
            context.delete(task)
        }
        try context.save()
    }

    private static func fetchTasks(in context: ModelContext) throws -> [DownloadTask] {
        let descriptor = FetchDescriptor<DownloadTask>()
        return try context.fetch(descriptor).sorted(by: isBefore)
    }

    private static func fetchChapter(
        bookPath: String,
        number: Int,
        in context: ModelContext
    ) throws -> ChapterRecord? {
        let id = ChapterRecord.makeId(bookPath: bookPath, number: number)
        return try context.fetch(FetchDescriptor<ChapterRecord>()).first { $0.id == id }
    }

    private static func apply(_ mutation: DownloadTaskMutation, to task: DownloadTask) {
        switch mutation {
        case .markDownloading:
            task.markDownloading()
        case .pauseByUser:
            task.pauseByUser()
        case let .pauseBlocked(message):
            task.pauseBlocked(error: message)
        case let .markFailed(message):
            task.markFailed(error: message)
        case .requeue:
            task.requeue()
        }
    }

    private static func snapshots(from tasks: [DownloadTask]) -> [DownloadTaskSnapshot] {
        tasks.sorted(by: isBefore).map(DownloadTaskSnapshot.init(task:))
    }

    private static func isBefore(_ first: DownloadTask, _ second: DownloadTask) -> Bool {
        if first.createdAt != second.createdAt {
            return first.createdAt < second.createdAt
        }
        if first.bookPath != second.bookPath {
            return first.bookPath < second.bookPath
        }
        return first.chapterNumber < second.chapterNumber
    }
}
