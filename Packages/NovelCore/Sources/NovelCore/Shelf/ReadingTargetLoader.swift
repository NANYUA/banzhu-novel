import Dependencies
import Foundation

/// 「单点书卡直接进阅读页」的落点：整本目录 + 该停在哪一章、章内哪个字符偏移。
///
/// ## 为什么把目录也带上（而不是只给章节路径）
/// 阅读页要的是 `ReaderView.init(chapters:)` —— 章尾无缝换章、跳章条、目录 sheet
/// 全靠这份**有序**章节列表。把「目录 + 落点」一次带过去，调用方拿到的就是
/// 可以直接开读的完整入参，不需要自己再拼一遍。
public struct ReadingTarget: Equatable, Sendable {
    public init(
        bookPath: String,
        chapterPath: String,
        chapterName: String,
        chapters: [ChapterItem],
        initialOffset: Int
    ) {
        self.bookPath = bookPath
        self.chapterPath = chapterPath
        self.chapterName = chapterName
        self.chapters = chapters
        self.initialOffset = initialOffset
    }

    /// 书路径（`BookRecord.bookPath`），阅读页的「更多 → 书籍详情」也用它。
    public let bookPath: String

    /// 要打开的章节路径。
    public let chapterPath: String

    /// 要打开的章节名（第一页标题用）。
    public let chapterName: String

    /// 整本书的**有序**章节列表。
    public let chapters: [ChapterItem]

    /// 首次加载要恢复到的字符偏移（数据契约 ③：偏移不是页码）。
    /// 从没读过、或进度指向的章节已不在目录里时是 `0`。
    public let initialOffset: Int
}

/// 解析某本书「该从哪里接着读」。
///
/// ## 为什么收在 NovelCore，而不是让 App 自己拼
/// 目录来源 `chapterListLoader` 是**模块内**依赖（App 拿不到），
/// 而「进度指向的章节已不在目录里 ⇒ 退回第一章第一页」是一条业务规则 ——
/// 放这里，书架与本地（下载）页两条入口共用同一份实现，不会各写一遍、各漂一次。
///
/// ## 读侧进度依赖
/// 进度真值来自 `ReadingProgressStore.load(bookPath)`（另一处实现，见该文件）：
/// 返回 `nil` = 这本书**从未读过** ⇒ 走「第一章第一页」。
public struct ReadingTargetLoader: Sendable {
    /// 入参：
    /// - `bookPath`：书路径。
    /// - `progressHint`：调用方**已经在内存里**的进度快照（书架行 `ShelfRow` 的
    ///   `lastReadChapterPath` / `lastReadOffset`）。给了就**不读库**；
    ///   本地（下载）页没有行模型，传 `nil` ⇒ 由本依赖读 `ReadingProgressStore`。
    ///
    /// 返回值 `nil` = 这本书**没有目录快照**（从未联网打开过）⇒ 阅读页打不开，
    /// 由调用方给出可感知的失败反馈。
    public var load: @Sendable (_ bookPath: String, _ progressHint: ReadingProgress?) async throws -> ReadingTarget?

    public init(
        load: @escaping @Sendable (String, ReadingProgress?) async throws -> ReadingTarget?
    ) {
        self.load = load
    }
}

extension DependencyValues {
    /// 阅读落点解析器。测试里用 `withDependencies { $0.readingTargetLoader.load = { … } }` 替换。
    public var readingTargetLoader: ReadingTargetLoader {
        get { self[ReadingTargetLoaderKey.self] }
        set { self[ReadingTargetLoaderKey.self] = newValue }
    }

    private enum ReadingTargetLoaderKey: DependencyKey {
        static let liveValue = ReadingTargetLoader { bookPath, progressHint in
            try await ReadingTargetLoaderLive().load(bookPath: bookPath, progressHint: progressHint)
        }

        /// 测试默认值：没有目录 ⇒ 打不开阅读页，避免忘记注入桩的测试意外读真库。
        static let testValue = ReadingTargetLoader { _, _ in nil }
    }
}

/// 真实实现：目录快照 + 阅读进度 → 落点。
///
/// 两个来源都走**既有依赖**，本类型只做「合并 + 退化规则」，自己不碰 SwiftData。
struct ReadingTargetLoaderLive {
    @Dependency(\.chapterListLoader) var chapterListLoader
    @Dependency(\.readingProgressStore) var readingProgressStore

    func load(bookPath: String, progressHint: ReadingProgress?) async throws -> ReadingTarget? {
        let chapters = try await chapterListLoader.load(bookPath)
        // 没有目录快照 ⇒ 打不开（阅读页的换章 / 跳章条 / 目录都依赖它）。
        guard let firstChapter = chapters.first else { return nil }

        // 书架行上已有同一份快照（同一次读库投影出来的）⇒ 不必再读一次；
        // 本地（下载）页没有行模型，`nil` ⇒ 读 `ReadingProgressStore`。
        let progress = if let progressHint {
            progressHint
        } else {
            try await readingProgressStore.load(bookPath)
        }

        // 进度指向的章节不在目录里（目录被重建过 / 章节被删）⇒ 退回第一章第一页。
        // 此时偏移**必须归零**：把旧章节的偏移套到新章节上会落到文中的任意位置。
        guard let chapter = chapters.first(where: { $0.path == progress?.chapterPath }) else {
            return ReadingTarget(
                bookPath: bookPath,
                chapterPath: firstChapter.path,
                chapterName: firstChapter.name,
                chapters: chapters,
                initialOffset: 0
            )
        }

        return ReadingTarget(
            bookPath: bookPath,
            chapterPath: chapter.path,
            chapterName: chapter.name,
            chapters: chapters,
            initialOffset: progress?.offset ?? 0
        )
    }
}
