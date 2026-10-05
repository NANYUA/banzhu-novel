import Foundation
import SwiftData

/// 下载任务状态。
enum DownloadState: String, Codable, CaseIterable {
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

    var isFinished: Bool {
        self == .done
    }

    /// 是否还占用队列（决定它排在前面还是后面）
    var isActive: Bool {
        self == .queued || self == .downloading
    }
}

/// 单个章节的下载任务。
///
/// ## 🔴 为什么要落库，而不是只放内存
/// 需求明确：**保守速率下 5 本 × 200 章 ≈ 27 小时**。
/// 27 小时里 App 必然被息屏、切后台、断网、甚至被系统杀进程。
/// 队列若只活在内存，App 一重启就全丢，用户会以为「App 坏了」。
///
/// 另有一处必须记住：需求要求「**遇盾 / 403 自动暂停，不重试**」。
/// 引擎旧代码是「失败重试 3 次」——**在盾页上反复重试恰恰是最招封禁的行为**。
/// 故 `attempts` 只在**非盾类**失败时递增。
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

    /// 已重试次数。**遇盾导致的暂停不计入**（停下不是重试）
    var attempts: Int = 0

    var lastError: String?

    /// 遇到盾 / 403 时置 true，UI 提示「已暂停，可能需要过验证」
    var blockedByGuard: Bool = false

    var createdAt: Date
    var finishedAt: Date?

    init(
        bookPath: String, bookTitle: String, chapterPath: String,
        chapterName: String, chapterNumber: Int,
        state: DownloadState = .queued, createdAt: Date = Date()
    ) {
        // ⚠️ 这里必须写 self.：本类是 SwiftData @Model，init 的形参与属性**同名**，
        // 去掉 self. 会退化成「形参赋给形参」，属性实际根本没被赋值。
        // 用内联指令豁免 SwiftFormat 的 redundantSelf 规则——这不是风格问题，是正确性问题。
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

    /// 🔴 遇盾 / 403：**暂停，不重试**（停下不是重试，故不递增 attempts）
    func pauseBlocked(error: String) {
        state = .paused
        blockedByGuard = true
        lastError = error
    }

    /// 普通失败（网络抖动、超时等）：计入重试次数
    func markFailed(error: String) {
        state = .failed
        blockedByGuard = false
        lastError = error
        attempts += 1
    }

    /// 重新入队（只重试这一项）
    func requeue() {
        state = .queued
        lastError = nil
        blockedByGuard = false
        finishedAt = nil
    }
}
