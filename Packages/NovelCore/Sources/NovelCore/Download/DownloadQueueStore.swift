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

    /// 删除一批书**已下载**的正文，并把对应 `ChapterRecord` 复位为「未下载」。
    ///
    /// 与 `complete(taskID:text:)` **互为逆操作**：那条把正文写盘并置
    /// `source = .downloaded`，这条把正文删掉并复位 `source = .notDownloaded`
    /// （复位会同时清掉 `localFileName` / `savedAt`）。
    /// 「正文落盘」既在本层，删除也归本层 —— 只留一个真相源，不另开一套删文件的依赖。
    var removeDownloadedChapters: @Sendable ([String]) async throws -> Void
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
            remove: { try await DownloadQueueStoreLive.remove($0) },
            removeDownloadedChapters: {
                try await DownloadQueueStoreLive.removeDownloadedChapters(bookPaths: $0)
            }
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
            remove: { _ in },
            removeDownloadedChapters: { _ in }
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
                //
                // ⚠️ **正在下载**的也不要碰：`requeue()` 会把它退回 `queued`，
                // 而在飞请求的结果回来时 `DownloadFeature` 只认 `state == .downloading`，
                // 于是这次结果被丢弃 —— 白下一次，进度还会倒退。
                if existing.state != .done, existing.state != .downloading {
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

    /// 删除一批书**已下载**的正文，并把对应 `ChapterRecord` 复位。
    ///
    /// ## 为什么走这条，而不是缓存淘汰
    /// 这是**用户主动删除**，不是 LRU 淘汰：`CacheEvictionPlanner` / `evictCachedChapters`
    /// 那条路的候选集**只含 `.cached`**（用户下载的章节按契约永不被它选中），
    /// 拿它来删 `.downloaded` 既删不掉、语义也不对。
    ///
    /// ## 只删 `.downloaded`，不动 `.cached`
    /// 「已下载」的唯一真相是 `ChapterRecord.source == .downloaded`（契约①）。
    /// `.cached`（阅读时自动缓存）不属于「已下载」，它有自己的淘汰规则，本动作不碰。
    ///
    /// ## 复位而不是删记录
    /// `ChapterRecord` 同时是**目录快照**（离线时靠它显示最新章节与未读章数），
    /// 所以只把 `source` 复位成 `.notDownloaded`（setter 会同时清掉
    /// `localFileName` / `savedAt`），不 `context.delete` —— 否则离线目录会凭空缺章。
    static func removeDownloadedChapters(bookPaths: [String]) throws {
        guard !bookPaths.isEmpty else { return }
        let context = try ModelContext(NovelStore.makeContainer())
        let selected = Set(bookPaths)
        let chapters = (try? context.fetch(FetchDescriptor<ChapterRecord>())) ?? []

        for chapter in chapters where selected.contains(chapter.bookPath) {
            guard chapter.source == .downloaded else { continue }
            // 先删文件、再复位来源（与 `NovelStore.evictCachedChapters` 同序）：
            // 反过来的话，中途失败会留下「文件还在、标记已清」的孤儿正文。
            NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number)
            chapter.source = .notDownloaded
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
