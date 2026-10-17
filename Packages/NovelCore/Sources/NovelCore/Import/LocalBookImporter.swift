import CryptoKit
import Dependencies
import Foundation
import SwiftData

/// 一次导入的入参。
public struct ImportRequest: Equatable, Sendable {
    /// 用户选中的 txt（可能是安全作用域 URL，读之前必须 `startAccessingSecurityScopedResource`）。
    public var fileURL: URL
    /// 书名。留空时用文件名兜底。
    public var title: String
    /// 作者。允许为空 —— 本地 txt 常常没有作者信息，**不编造**。
    public var author: String
    /// 当前启用中的规则表（由 `ImportRuleStore` 读出后原样传入；导入管线不认识 UserDefaults）。
    public var rules: [ImportChapterRule]

    public init(fileURL: URL, title: String, author: String, rules: [ImportChapterRule]) {
        self.fileURL = fileURL
        self.title = title
        self.author = author
        self.rules = rules
    }

    /// 文件名（去扩展名），用作书名兜底与错误文案。
    public var fileName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
}

/// 导入进度。界面只读这一个值。
public enum ImportProgress: Equatable, Sendable {
    case reading
    case splitting
    case writing(done: Int, total: Int)
}

/// 导入结果。
public struct ImportResult: Equatable, Sendable {
    public let bookPath: String
    public let title: String
    public let chapterCount: Int

    public init(bookPath: String, title: String, chapterCount: Int) {
        self.bookPath = bookPath
        self.title = title
        self.chapterCount = chapterCount
    }
}

/// 导入失败的业务错误（区别于文件系统 / 数据库错误）。
public enum ImportError: LocalizedError, Equatable {
    case alreadyExists(title: String)
    case cannotRead(fileName: String)
    case fileTooLarge(fileName: String, limitMB: Int)
    case noContent(fileName: String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyExists(title):
            "《\(title)》已经在书架里了。"
        case let .cannotRead(fileName):
            "读不到《\(fileName)》，请重新选择文件。"
        case let .fileTooLarge(fileName, limitMB):
            "《\(fileName)》超过 \(limitMB) MB，暂时不支持这么大的文件。"
        case let .noContent(fileName):
            "《\(fileName)》里没有可导入的正文。"
        }
    }
}

/// 导入相关的数值上限。
///
/// ## 为什么单独放一个 enum 而不是塞进 `LocalBookImporterLive`
/// `LocalBookImporterLive` 是 `@MainActor` 的，它的 `static let` 也带 actor 隔离 ——
/// 而下面这些常量要在 `Task.detached` 里用（解码 / 切章 / 落盘都在后台），
/// 从非隔离上下文读主 actor 的静态属性会直接编译不过。
private enum ImportLimits {
    /// 单文件上限。一次性读进内存 + 切章会产生数倍于文件大小的临时分配，
    /// 手机上 100MB 已是「勉强能撑」的边界，超过就明确拒绝而不是赌能不能活下来。
    static let maxFileBytes = 100 * 1024 * 1024
    static let maxFileMB = 100

    /// bookPath 用的哈希长度（SHA256 十六进制前 16 位 = 64 bit，碰撞概率可忽略）。
    static let hashLength = 16

    /// 每写多少章回报一次进度。太小会刷爆 SwiftUI 重绘，太大进度条看着像卡住。
    static let progressStride = 25
}

// MARK: - 依赖

/// 导入一本本地 txt（依赖）。
///
/// 与 `ShelfAdder` 分开的理由：加入书架要联网抓目录，导入完全在本地；
/// 两条写路径的失败模式、耗时特征、可测桩都不一样，合在一起只会互相牵制。
struct LocalBookImporter: Sendable {
    /// 第二个参数是进度回调：**串行 await**，保证界面收到的进度单调递增。
    var importFile: @Sendable (ImportRequest, @Sendable (ImportProgress) async -> Void) async throws
        -> ImportResult
}

extension DependencyValues {
    var localBookImporter: LocalBookImporter {
        get { self[LocalBookImporterKey.self] }
        set { self[LocalBookImporterKey.self] = newValue }
    }

    private enum LocalBookImporterKey: DependencyKey {
        static let liveValue = LocalBookImporter { request, onProgress in
            try await LocalBookImporterLive.perform(request: request, onProgress: onProgress)
        }

        /// 测试默认值直接抛错。写入类依赖的默认值必须「吵闹」，
        /// 否则忘记注入桩的测试会因为「导入了 0 章」而假通过。
        static let testValue = LocalBookImporter { _, _ in
            throw ImportError.cannotRead(fileName: "(未注入桩)")
        }
    }
}

// MARK: - 真实实现

/// 真实实现：读文件 → 算哈希 → 查重 → 解码 → 切章 → 逐章落盘 → 一次落库。
///
/// ## 为什么整体 `@MainActor`，重活却丢进 `Task.detached`
/// SwiftData 的 `ModelContext` 只能在主 actor 上安全使用 ⇒ **落库**必须留在主 actor；
/// 但解码、切章、几千次文件写入如果也占着主线程，界面会直接冻住（进度条都不动）。
/// ⇒ 纯计算 / 纯文件 IO 放进 `Task.detached`，主 actor 只做「插记录 + save」。
///
/// ## 🔴 绝不走 `ChapterCacheStore.saveCachedText`
/// 那个方法会把 `source != .downloaded` 的章节标成 `.cached`（`ChapterCacheStore.swift:152-155`），
/// 导入书一旦被标成缓存就会被 LRU 当垃圾删掉 —— 直接破契约 ①（下载章永不淘汰）。
/// 所以这里**自己写正文文件 + 自己建 `.downloaded` 记录**。
@MainActor
enum LocalBookImporterLive {
    /// 生产入口：自己开容器。
    static func perform(
        request: ImportRequest,
        onProgress: @Sendable (ImportProgress) async -> Void
    ) async throws -> ImportResult {
        let container = try NovelStore.makeContainer()
        return try await perform(request: request, onProgress: onProgress, container: container)
    }

    /// 测试入口：容器由调用方提供（内存容器），不碰真实沙盒数据库。
    static func perform(
        request: ImportRequest,
        onProgress: @Sendable (ImportProgress) async -> Void,
        container: ModelContainer
    ) async throws -> ImportResult {
        let fileName = request.fileName
        let data = try readData(url: request.fileURL, fileName: fileName)
        let bookPath = LocalBookPath.bookPath(hash: sha256PrefixHex(data))
        let context = ModelContext(container)
        try ensureNotExisting(bookPath: bookPath, in: context)

        let text = try await decode(data, fileName: fileName, onProgress: onProgress)
        let chapters = await split(text: text, rules: request.rules, onProgress: onProgress)
        guard !chapters.isEmpty else { throw ImportError.noContent(fileName: fileName) }

        do {
            try await write(chapters, bookPath: bookPath, onProgress: onProgress)
            let title = resolvedTitle(request)
            try insertRecords(
                bookPath: bookPath,
                title: title,
                author: request.author.trimmingCharacters(in: .whitespacesAndNewlines),
                chapters: chapters,
                into: context
            )
            return ImportResult(bookPath: bookPath, title: title, chapterCount: chapters.count)
        } catch {
            // 半成品必须清掉：没有 BookRecord 的 `Content/local_<hash>/` 是纯垃圾，
            // 而且下次导入同一文件会复用这个目录、往旧文件上覆盖。
            discardChapterFiles(bookPath: bookPath)
            throw error
        }
    }

    // MARK: - 各步

    private static func readData(url: URL, fileName: String) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        // 先看大小再读：直接读一个 500MB 的文件会当场被系统杀掉。
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ImportLimits.maxFileBytes else {
            throw ImportError.fileTooLarge(fileName: fileName, limitMB: ImportLimits.maxFileMB)
        }
        // 刻意不用 `.mappedIfSafe`：映射读是惰性的，而安全作用域访问在上面就被 `stop` 了，
        // 之后一旦触发分页读可能失败（表现为「读一半报错」）。
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.cannotRead(fileName: fileName)
        }
        guard data.count <= ImportLimits.maxFileBytes else {
            throw ImportError.fileTooLarge(fileName: fileName, limitMB: ImportLimits.maxFileMB)
        }
        return data
    }

    private static func sha256PrefixHex(_ data: Data) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
        return String(hex.prefix(ImportLimits.hashLength))
    }

    private static func ensureNotExisting(bookPath: String, in context: ModelContext) throws {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        descriptor.fetchLimit = 1
        if let found = try? context.fetch(descriptor).first {
            throw ImportError.alreadyExists(title: found.title)
        }
    }

    private static func decode(
        _ data: Data,
        fileName: String,
        onProgress: @Sendable (ImportProgress) async -> Void
    ) async throws -> String {
        await onProgress(.reading)
        return try await Task.detached(priority: .userInitiated) {
            try TextDecoder.decode(data, fileName: fileName)
        }.value
    }

    private static func split(
        text: String,
        rules: [ImportChapterRule],
        onProgress: @Sendable (ImportProgress) async -> Void
    ) async -> [ChapterSplitter.Chapter] {
        await onProgress(.splitting)
        return await Task.detached(priority: .userInitiated) {
            ChapterSplitter.split(text: text, rules: rules)
        }.value
    }

    /// 逐章落盘。几千章时这是整条链路最慢的一步，所以它**支持取消**：
    /// 每章开头 `Task.checkCancellation()`，调用方（sheet 被关掉 ⇒ effect 被取消）
    /// 一取消，下一次检查就抛出 `CancellationError`。
    ///
    /// ## 为什么每章单独丢进 `Task.detached`，而不是整段包一个
    /// `onProgress` 是**非逃逸**参数（调用方不需要把回调存起来），
    /// 而 `Task.detached` 的闭包是逃逸的 —— 整段包起来会报
    /// 「escaping closure captures non-escaping parameter 'onProgress'」（CI 实测）。
    /// 只把「纯文件 IO」放进 detached、进度回报留在原地，就绕开了这个约束，
    /// 同时 IO 依旧不占主线程。
    private static func write(
        _ chapters: [ChapterSplitter.Chapter],
        bookPath: String,
        onProgress: @Sendable (ImportProgress) async -> Void
    ) async throws {
        let total = chapters.count
        await onProgress(.writing(done: 0, total: total))
        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            try await Task.detached(priority: .userInitiated) {
                _ = try NovelStore.saveChapterText(chapter.body, bookPath: bookPath, number: number)
            }.value
            if number % ImportLimits.progressStride == 0 || number == total {
                await onProgress(.writing(done: number, total: total))
            }
        }
    }

    /// 落库：一条 `BookRecord` + 每章一条 `.downloaded` 的 `ChapterRecord`，最后**一次** save。
    ///
    /// 为什么一次 save 而不是逐章 save：SwiftData 的 save 是整库事务，
    /// 3000 章逐章 save 会把导入时间放大一个数量级。
    private static func insertRecords(
        bookPath: String,
        title: String,
        author: String,
        chapters: [ChapterSplitter.Chapter],
        into context: ModelContext
    ) throws {
        let record = BookRecord(bookPath: bookPath, title: title, author: author)
        // 目录快照：书架离线也要能显示「最新章节」与「共 N 章」。
        record.latestChapterName = chapters.last?.title
        record.latestChapterCount = chapters.count
        context.insert(record)

        for (index, chapter) in chapters.enumerated() {
            let number = index + 1
            context.insert(
                ChapterRecord(
                    bookPath: bookPath,
                    number: number,
                    name: chapter.title,
                    path: LocalBookPath.chapterPath(bookPath: bookPath, number: number),
                    source: .downloaded,
                    localFileName: NovelStore.chapterFileName(number: number)
                )
            )
        }
        do {
            try context.save()
        } catch {
            // save 失败就把内存里的半成品撤掉，否则它们会跟着下一次 save 一起落库，
            // 变成「书在、章不全」的半损坏状态。
            context.rollback()
            throw error
        }
    }

    private static func discardChapterFiles(bookPath: String) {
        try? FileManager.default.removeItem(at: NovelStore.bookDir(forBookPath: bookPath))
    }

    private static func resolvedTitle(_ request: ImportRequest) -> String {
        let trimmed = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? request.fileName : trimmed
    }
}
