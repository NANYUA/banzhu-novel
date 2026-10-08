import Foundation

/// 入队请求：只包含章节定位信息，不把 SwiftData 模型带进 reducer 状态。
public struct DownloadChapterRequest: Equatable, Sendable {
    public init(
        bookPath: String,
        bookTitle: String,
        chapterPath: String,
        chapterName: String,
        chapterNumber: Int
    ) {
        self.bookPath = bookPath
        self.bookTitle = bookTitle
        self.chapterPath = chapterPath
        self.chapterName = chapterName
        self.chapterNumber = chapterNumber
    }

    public let bookPath: String
    public let bookTitle: String
    public let chapterPath: String
    public let chapterName: String
    public let chapterNumber: Int
}

/// 下载任务的只读投影。
///
/// SwiftData 的 `@Model` 不是 `Sendable`，不能直接跨 Effect 边界；
/// reducer 的状态只保存这个值类型，数据库模型留在存储依赖里。
public struct DownloadTaskSnapshot: Equatable, Sendable, Identifiable {
    public init(
        id: String,
        bookPath: String,
        bookTitle: String,
        chapterPath: String,
        chapterName: String,
        chapterNumber: Int,
        state: DownloadState,
        attempts: Int,
        lastError: String?,
        blockedByGuard: Bool,
        createdAt: Date,
        finishedAt: Date?
    ) {
        self.id = id
        self.bookPath = bookPath
        self.bookTitle = bookTitle
        self.chapterPath = chapterPath
        self.chapterName = chapterName
        self.chapterNumber = chapterNumber
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.blockedByGuard = blockedByGuard
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }

    init(task: DownloadTask) {
        id = task.id
        bookPath = task.bookPath
        bookTitle = task.bookTitle
        chapterPath = task.chapterPath
        chapterName = task.chapterName
        chapterNumber = task.chapterNumber
        state = task.state
        attempts = task.attempts
        lastError = task.lastError
        blockedByGuard = task.blockedByGuard
        createdAt = task.createdAt
        finishedAt = task.finishedAt
    }

    public let id: String
    public let bookPath: String
    public let bookTitle: String
    public let chapterPath: String
    public let chapterName: String
    public let chapterNumber: Int

    public var state: DownloadState
    public var attempts: Int
    public var lastError: String?
    public var blockedByGuard: Bool
    public let createdAt: Date
    public var finishedAt: Date?
}
