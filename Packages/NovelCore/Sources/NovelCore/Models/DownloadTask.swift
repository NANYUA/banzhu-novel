import Foundation
import SwiftData

/// 下载任务状态。
public enum DownloadState: String, Codable, CaseIterable, Sendable {
    /// 已入队等待
    case queued
    /// 正在抓取
    case downloading
    /// 已暂停（用户主动，或遇盾/403 自动暂停）
    case paused
    /// 已完成
    case done
    /// 失败（可单独重试）
    case failed

    public var isFinished: Bool {
        self == .done
    }

    /// 是否还占用队列（决定它排在前面还是后面）
    public var isActive: Bool {
        self == .queued || self == .downloading
    }
}

/// 单个章节的下载任务。
///
/// ## 为什么要落库，而不是只放内存
/// 保守速率下批量下载会持续很久，App 可能被息屏、切后台、断网甚至被杀进程，
/// 队列只放内存会在重启后全部丢失。
///
/// ## 遇到验证拦截时为什么不能重试
/// 遇到验证拦截时继续重试只会让情况更糟，因此 `attempts` 只在普通网络失败时递增，
/// 拦截导致的是「暂停」而不是「重试」。
@Model
final class DownloadTask {
    /// 复合主键：`bookPath#chapterPath`
    @Attribute(.unique) var id: String

    var bookPath: String
    var bookTitle: String
    var chapterPath: String
    var chapterName: String
    var chapterNumber: Int

    var stateRaw: String

    /// 已重试次数。拦截导致的暂停不计入。
    var attempts: Int = 0

    var lastError: String?

    /// 遇到验证拦截或 403 时置 true，界面据此提示用户需要处理验证。
    var blockedByGuard: Bool = false

    var createdAt: Date
    var finishedAt: Date?

    init(
        bookPath: String, bookTitle: String, chapterPath: String,
        chapterName: String, chapterNumber: Int,
        state: DownloadState = .queued, createdAt: Date = Date()
    ) {
        // 本类是 SwiftData @Model，init 形参与属性同名；必须写 self.，
        // 否则会退化成「形参赋给形参」，属性实际没有被赋值。
        // swiftformat:disable redundantSelf
        self.id = Self.makeId(bookPath: bookPath, chapterPath: chapterPath)
        self.bookPath = bookPath
        self.bookTitle = bookTitle
        self.chapterPath = chapterPath
        self.chapterName = chapterName
        self.chapterNumber = chapterNumber
        self.stateRaw = state.rawValue
        // swiftformat:enable redundantSelf
        self.createdAt = createdAt
    }

    static func makeId(bookPath: String, chapterPath: String) -> String {
        "\(bookPath)#\(chapterPath)"
    }

    var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    /// 完成
    func markDone(at date: Date = Date()) {
        state = .done
        finishedAt = date
        lastError = nil
        blockedByGuard = false
    }

    /// 开始抓取
    func markDownloading() {
        state = .downloading
        finishedAt = nil
    }

    /// 用户主动暂停
    func pauseByUser() {
        state = .paused
        blockedByGuard = false
        lastError = nil
    }

    /// 遇到验证拦截 / 403：暂停，不重试（停下不是重试，故不递增 attempts）。
    func pauseBlocked(error: String) {
        state = .paused
        blockedByGuard = true
        lastError = error
    }

    /// 普通失败（网络抖动、超时等）：计入重试次数。
    func markFailed(error: String) {
        state = .failed
        blockedByGuard = false
        lastError = error
        attempts += 1
    }

    /// 重新入队（只重试这一项）。
    func requeue() {
        state = .queued
        lastError = nil
        blockedByGuard = false
        finishedAt = nil
    }
}
