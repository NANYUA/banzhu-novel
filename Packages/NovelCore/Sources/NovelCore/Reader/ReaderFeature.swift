import ComposableArchitecture
import CoreGraphics
import Dependencies
import Foundation

public enum PageTurnDirection: String, Equatable, Sendable {
    case forward
    case backward
}

/// 阅读页 —— 读一章正文，支持翻页。
///
/// ## 🔴 数据契约：state 存 characterOffset，不存页码
/// 页码会因字号/行距/页边距等设置变化而变；`currentOffset` 是字符偏移，
/// 改设置后依然能唯一定位到同一处文字。翻页用「当前 offset 反查所在页 →
/// 取相邻页的 location」完成，全程不引入页码。
///
/// ## 为什么不用 @Reducer 宏
/// 同 BookshelfFeature：CI 宏不可用，手写 Reducer 协议。
/// 保留 @Dependency（property wrapper，非宏）。
public struct ReaderFeature: Reducer {
    public init() {}

    /// 自动预缓存后续章节数的默认值与上限。
    public static let defaultPrecacheCount = 3
    public static let maxPrecacheCount = 20

    public struct State: Equatable {
        public init(
            chapterPath: String,
            chapterName: String = "",
            text: String = "",
            config: PaginationConfiguration = PaginationConfiguration(
                containerSize: CGSize(width: 320, height: 480)
            ),
            currentOffset: Int = 0,
            pageTurnDirection: PageTurnDirection = .forward,
            isLoading: Bool = false,
            errorMessage: String? = nil,
            precacheCount: Int = ReaderFeature.defaultPrecacheCount,
            chapters: [ChapterItem] = [],
            initialOffset: Int = 0
        ) {
            self.chapterPath = chapterPath
            self.chapterName = chapterName
            self.text = text
            self.config = config
            self.currentOffset = currentOffset
            self.pageTurnDirection = pageTurnDirection
            self.isLoading = isLoading
            self.errorMessage = errorMessage
            self.precacheCount = precacheCount
            self.chapters = chapters
            self.initialOffset = initialOffset
        }

        /// 当前章节路径（如 `/49/49034/123.html`）
        public var chapterPath: String

        /// 当前章节名。第一页会作为纯文本标题参与统一分页。
        public var chapterName: String

        /// 本章正文本体
        public var text: String

        /// 分页配置。改了会触发重新分页
        public var config: PaginationConfiguration

        /// 🔴 阅读位置：字符偏移，**不是页码**。
        /// 改设置后靠它重新定位到同一处文字。
        public var currentOffset: Int

        /// 首次加载时要恢复到的字符偏移（由 App 从持久化进度读入）。
        ///
        /// **只消费一次**：`contentLoaded` 恢复位置后立刻归零（见
        /// `consumeInitialOffset`）⇒ 之后换章 / 从目录跳章仍从章首开始，既有语义不变。
        public var initialOffset: Int = 0

        /// 最近一次翻页方向，用于让动画与手势方向一致。
        public var pageTurnDirection: PageTurnDirection

        /// 首次加载中
        public var isLoading = false

        /// 加载失败原因
        public var errorMessage: String?

        /// 自动预缓存后续章节数；默认 3，0 表示只缓存当前章。
        public var precacheCount: Int

        /// 分页结果（每次内容/配置变化后重算）。
        /// `pages` 不持久化、不直接进 App —— App 用 `currentOffset` 定位。
        public var pages: [PageRange] = []

        /// 整本书的**有序**章节列表（App 在创建阅读页时声明，来源是目录快照 `ChapterItem`）。
        ///
        /// 阅读器只用它推「下一章」—— 到章尾要无缝切过去的那一章。
        /// 为空、或列表里找不到 `chapterPath` ⇒ 没有下一章，到章尾保持回弹（不提示）。
        public var chapters: [ChapterItem] = []

        /// 下一章正文（预加载结果）；空串表示还没就绪。
        public var nextText: String = ""

        /// 下一章的分页结果，与 `config` **同源**（换章后 config 不变，分页才对得上渲染盒）。
        /// 空数组 = 不可用（没预加载 / 加载失败 / 分页为空）⇒ 到章尾回弹。
        public var nextPages: [PageRange] = []

        /// 上一章正文（预加载结果）；空串表示还没就绪。
        public var previousText: String = ""

        /// 上一章的分页结果，与 `config` **同源**（退章后 config 不变，分页才对得上渲染盒）。
        /// 空数组 = 不可用（没预加载 / 加载失败 / 分页为空）⇒ 到章首回弹。
        public var previousPages: [PageRange] = []
    }

    /// 显式 Equatable：TestStore.receive 需要
    public enum Action: Equatable {
        /// 加载一章
        case loadChapter(String)
        /// 加载指定章节并带章名，用于章节内第一页标题。
        case loadChapterWithName(String, String)
        /// 内容加载完成
        case contentLoaded(String)
        /// 加载失败
        case loadFailed(String)
        /// 下一页
        case nextPage
        /// 上一页
        case prevPage
        /// 到章尾再往前：切到下一章。
        /// 下一章第 1 页此刻就摆在全景图的 `+1` 格上，所以这里只做状态迁移、不重新加载。
        case advanceChapter
        /// 下一章正文预加载完成（章节路径 + 正文）；分页由 reducer 按**当前** config 现算。
        case nextChapterLoaded(String, String)
        /// 到章首再往后：切到上一章**最后一页**。
        /// 上一章最后一页此刻就摆在全景图的 `-1` 格上，所以这里只做状态迁移、不重新加载。
        case retreatChapter
        /// 上一章正文预加载完成（章节路径 + 正文）；分页由 reducer 按**当前** config 现算。
        case previousChapterLoaded(String, String)
        /// 分页配置变化（触发重算分页 + 按 offset 重新定位）
        case configChanged(PaginationConfiguration)
        /// 自动预缓存后续章节数变化
        case precacheCountChanged(Int)
        /// 从持久化恢复阅读设置
        case loadSavedSettings(CGSize)
        /// 页面容器尺寸变化（首次布局 / 旋转 / 分屏 / 换机型）
        case containerSizeChanged(CGSize)
        /// 持久化设置读取完成（带页面容器尺寸，恢复时合并出完整配置）
        case settingsLoaded(ReadingSettings, CGSize)
    }

    @Dependency(\.readerLoader) var readerLoader
    @Dependency(\.paginationService) var paginationService
    @Dependency(\.readingProgressStore) var readingProgressStore
    @Dependency(\.chapterCacheStore) var chapterCacheStore
    @Dependency(\.readingSettingsStore) var readingSettingsStore

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .loadChapter(path):
                state.chapterPath = path
                state.chapterName = ""
                state.isLoading = true
                state.errorMessage = nil
                state.text = ""
                state.pages = []
                state.currentOffset = 0
                // 换章（含从目录手动跳章）⇒ 旧的预加载结果作废，不能把别的章的
                // 「下一章」/「上一章」错配给这一章。相邻两章都在本章 `contentLoaded` 后预加载。
                invalidateNextChapter(&state)
                invalidatePreviousChapter(&state)
                let loader = readerLoader
                return .run { send in
                    do {
                        let text = try await loader.load(path)
                        await send(.contentLoaded(text))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .loadChapterWithName(path, name):
                state.chapterPath = path
                state.chapterName = name
                state.isLoading = true
                state.errorMessage = nil
                state.text = ""
                state.pages = []
                state.currentOffset = 0
                invalidateNextChapter(&state)
                invalidatePreviousChapter(&state)
                let loader = readerLoader
                return .run { send in
                    do {
                        let text = try await loader.load(path)
                        await send(.contentLoaded(text))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .contentLoaded(text):
                state.text = text
                state.isLoading = false
                // 内容变化 → 重新分页
                state.pages = paginationService.paginate(state.displayText, state.config)
                // 只有**首次**加载才恢复持久化位置：取出即归零 ⇒ 换章 / 从目录跳章仍从章首开始。
                let restoredOffset = state.consumeInitialOffset()
                state.currentOffset = restoredOffset
                let chapterPath = state.chapterPath
                // 🔴 落盘的是**本次恢复后的偏移**，不是 0：恒写 0 会把刚恢复的位置当场抹掉，
                // 下次进来只能回到章首（owner 真机反馈「换一本书以后只会回到看的章节首页」）。
                // ⚠️ 必须在 `consumeInitialOffset()` **之后**取：`progressOffset` 是
                // `currentOffset` 的派生值，而恢复位置正是由它写进 `currentOffset` 的。
                // ⚠️ 口径用 `progressOffset`（相对**原始正文**，已扣掉章名前缀），
                // 与 `ReadingProgressStore` 落盘口径一致 —— 直接写 `currentOffset` 会多算
                // 一个章名前缀长度（换章 / 带章名时正好差一整页）。
                let progressOffset = state.progressOffset
                let progressStore = readingProgressStore
                let cacheStore = chapterCacheStore
                let precacheCount = state.precacheCount
                return .merge(
                    .run { _ in
                        // 进度写入失败不应阻断阅读；书架排序与 LRU 会在下次成功时刷新。
                        try? await progressStore.markRead(chapterPath, progressOffset, Date())
                        await cacheStore.cacheCurrentAndFollowing(chapterPath, text, precacheCount)
                    },
                    // 本章就绪后才预加载相邻两章：到章尾 / 章首那一格才有内容可翻。
                    // 顺序固定为「先下一章、后上一章」（见 `preloadAdjacentChapters`）。
                    preloadAdjacentChapters(state, loader: readerLoader)
                )

            case let .loadFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .nextPage:
                let pageIndex = state.currentPageIndex
                guard pageIndex >= 0, pageIndex + 1 < state.pages.count else {
                    return .none // 已是最后一页
                }
                state.pageTurnDirection = .forward
                state.currentOffset = state.pages[pageIndex + 1].location
                return saveProgress(
                    chapterPath: state.chapterPath,
                    offset: state.progressOffset,
                    store: readingProgressStore
                )

            case .prevPage:
                let pageIndex = state.currentPageIndex
                guard pageIndex > 0 else {
                    return .none // 已是第一页
                }
                state.pageTurnDirection = .backward
                state.currentOffset = state.pages[pageIndex - 1].location
                return saveProgress(
                    chapterPath: state.chapterPath,
                    offset: state.progressOffset,
                    store: readingProgressStore
                )

            case .advanceChapter:
                return advanceToNextChapter(
                    &state,
                    loader: readerLoader,
                    progressStore: readingProgressStore,
                    cacheStore: chapterCacheStore
                )

            case let .nextChapterLoaded(path, text):
                return applyNextChapterLoaded(
                    path: path,
                    text: text,
                    to: &state,
                    using: paginationService
                )

            case .retreatChapter:
                return retreatToPreviousChapter(
                    &state,
                    loader: readerLoader,
                    progressStore: readingProgressStore,
                    cacheStore: chapterCacheStore
                )

            case let .previousChapterLoaded(path, text):
                return applyPreviousChapterLoaded(
                    path: path,
                    text: text,
                    to: &state,
                    using: paginationService
                )

            case let .configChanged(newConfig):
                guard newConfig != state.config else { return .none }
                let shouldRepaginate = newConfig.affectsPagination(comparedTo: state.config)
                state.config = newConfig
                // 只有影响排版的设置才重新分页；背景色 / 翻页方式等直接生效。
                if shouldRepaginate {
                    repaginate(&state, using: paginationService)
                    // 🔴 数据契约：改设置后用 offset 重新定位，不丢位置。
                }
                let settingsStore = readingSettingsStore
                let settings = ReadingSettings(
                    configuration: state.config,
                    precacheCount: state.precacheCount
                )
                return .run { _ in
                    settingsStore.save(settings)
                }

            case let .precacheCountChanged(count):
                let clamped = min(max(0, count), Self.maxPrecacheCount)
                guard clamped != state.precacheCount else { return .none }
                state.precacheCount = clamped
                let settingsStore = readingSettingsStore
                let settings = ReadingSettings(
                    configuration: state.config,
                    precacheCount: state.precacheCount
                )
                return .run { _ in
                    settingsStore.save(settings)
                }

            case let .loadSavedSettings(size):
                // 🔴 容器尺寸永远以页面布局为准（ReadingSettings 刻意不落盘）。
                // 没有已保存设置时也要写进去，否则分页会一直按默认 320×480 算，
                // 正文只占屏幕一部分（比例错乱）。
                applyContainerSize(size, to: &state, using: paginationService)
                let settingsStore = readingSettingsStore
                return .run { send in
                    guard let settings = settingsStore.load() else { return }
                    await send(.settingsLoaded(settings, size))
                }

            case let .containerSizeChanged(size):
                // 旋转 / 分屏 / 换机型：尺寸变了重新分页，currentOffset 不重置。
                applyContainerSize(size, to: &state, using: paginationService)
                return .none

            case let .settingsLoaded(settings, size):
                let merged = settings.mergedConfiguration(containerSize: size)
                let shouldRepaginate = merged.affectsPagination(comparedTo: state.config)
                state.config = merged
                state.precacheCount = min(max(settings.precacheCount, 0), Self.maxPrecacheCount)
                if shouldRepaginate {
                    repaginate(&state, using: paginationService)
                }
                return .none
            }
        }
    }
}

/// 写一条阅读进度。
///
/// ⚠️ 不是 `private`：`ReaderFeature+ChapterTransition.swift` 里的换章迁移
/// （`advanceToNextChapter` / `retreatToPreviousChapter`）也走这条口径。
func saveProgress(
    chapterPath: String,
    offset: Int,
    store: ReadingProgressStore
) -> Effect<ReaderFeature.Action> {
    .run { _ in
        try? await store.markRead(chapterPath, offset, Date())
    }
}

/// `ReaderFeature.State` 的派生值（只读投影，没有自己的存储）。
///
/// 单独放 extension：`ReaderFeature` 的类型体贴着 SwiftLint `type_body_length`
/// 250 行的门槛（CI `--strict` 下 warning 即失败），而**声明在父类型大括号之外**的
/// extension **不计入**该指标 ⇒ 计算属性与静态函数一律搬到这里，存储属性与 `init`
/// 必须留在 `struct State` 里（搬出去编译不过）。
public extension ReaderFeature.State {
    /// 渲染与分页使用的文本：章节名作为普通正文前缀。
    ///
    /// 规则抽成静态函数，因为**下一章**（`nextDisplayText`）必须与它逐字同源：
    /// 换章时预加载的 `nextPages` 直接当新章的分页用，规则一分叉就与渲染错位。
    static func displayText(chapterName: String, text: String) -> String {
        guard !chapterName.isEmpty else { return text }
        let normalizedTitle = chapterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return text }
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedText.hasPrefix(normalizedTitle) {
            return text
        }
        return normalizedTitle + "\n\n" + text
    }

    var displayText: String {
        Self.displayText(chapterName: chapterName, text: text)
    }

    /// 标题前缀长度；持久化 characterOffset 时需要扣除。
    var titlePrefixLength: Int {
        max(0, displayText.count - text.count)
    }

    /// 对外持久化的字符偏移，始终相对原始正文。
    var progressOffset: Int {
        max(0, currentOffset - titlePrefixLength)
    }

    /// 取出首次加载要恢复的字符偏移（换算到 `displayText` 坐标系），并**立刻清空**（只恢复一次）。
    ///
    /// ## 🔴 两个坐标系（后人最容易搞错的地方）
    /// - `initialOffset` 来自持久化的 `progressOffset`，**相对原始正文** `text`
    ///   （落盘时扣掉了章名前缀，见 `progressOffset` / `titlePrefixLength`）；
    /// - `currentOffset` 与 `displayText` **含章名前缀**（`chapterName + "\n\n"`）。
    ///
    /// 两者相差一个 `titlePrefixLength` ⇒ 恢复时**必须加回前缀长度**，
    /// 否则位置会往前偏一个章名的宽度，正好跨页边界时就差一整页。
    /// 例如 `displayText = "第七章\n\n" + 10 字`（前缀 5、共 15 字）：
    /// 落盘的 `progressOffset = 5` 指的是**原始正文第 5 字**，
    /// 在 `displayText` 里它是第 10 字（第 3 页页首）而不是第 5 字（第 2 页页首）。
    ///
    /// ## 顺序：先加前缀，再夹取
    /// 加完之后才与 `displayText` 同坐标系，再夹到 `0 ... max(0, displayText.count - 1)`
    /// （正文为空、偏移越界都不越界）。
    ///
    /// ## `initialOffset == 0` 是「没有要恢复的位置」，不是「原始正文第 0 字」
    /// 默认值 0 / 已消费 / 从未看过都走这一支 ⇒ 返回 0（**章首第一页，含章名页**），
    /// 绝不能加前缀长度（否则「从未看过」会从章名之后开始，且换章语义被破坏）。
    ///
    /// 恢复后 `initialOffset` 归零 ⇒ 换章 / 从目录跳章仍从章首开始。
    mutating func consumeInitialOffset() -> Int {
        defer { initialOffset = 0 }
        guard initialOffset > 0 else { return 0 }
        let displayOffset = initialOffset + titlePrefixLength
        return min(max(0, displayOffset), max(0, displayText.count - 1))
    }

    /// 下一章；当前是最后一章、或列表里找不到当前章时为 `nil`。
    ///
    /// 派生自 `chapters` + `chapterPath` ⇒ **换章后自动指向新的下一章**，
    /// 不需要 App 再声明一次。
    var nextChapter: ChapterItem? {
        guard let index = chapters.firstIndex(where: { $0.path == chapterPath }),
              chapters.indices.contains(index + 1)
        else { return nil }
        return chapters[index + 1]
    }

    /// 上一章；当前是第一章、或列表里找不到当前章时为 `nil`。
    ///
    /// 与 `nextChapter` **同源同写法**（同一份 `chapters` + `chapterPath` 派生，同样
    /// 换章后自动指向新的上一章）。App 的「上一章」按钮用它决定是否置灰 ——
    /// 与「下一章」用同一条判据，两侧不会出现一个能点、一个不能点的分叉。
    var previousChapter: ChapterItem? {
        guard let index = chapters.firstIndex(where: { $0.path == chapterPath }),
              chapters.indices.contains(index - 1)
        else { return nil }
        return chapters[index - 1]
    }

    /// 下一章的渲染文本（与 `displayText` 同一合成规则）。
    var nextDisplayText: String {
        guard let next = nextChapter else { return "" }
        return Self.displayText(chapterName: next.name, text: nextText)
    }

    /// 上一章的渲染文本（与 `displayText` 同一合成规则）。
    ///
    /// 与 `nextDisplayText` 同源同写法：全景图 `-1` 格切页要用它，退章时
    /// `previousPages` 直接当新章的分页用 —— 规则一分叉就与渲染错位。
    var previousDisplayText: String {
        guard let previous = previousChapter else { return "" }
        return Self.displayText(chapterName: previous.name, text: previousText)
    }

    /// 当前 offset 落在第几页。`-1` 表示还没分页（空文本）
    var currentPageIndex: Int {
        guard !pages.isEmpty else { return -1 }
        // pages 按 location 升序，二分或线性找 currentOffset 落在哪页
        for (index, page) in pages.enumerated() {
            if currentOffset >= page.location, currentOffset < page.location + page.length {
                return index
            }
        }
        // 兜底：currentOffset 在末尾边界，归最后一页
        return pages.count - 1
    }
}

/// 把真实容器尺寸写进配置；只有变了才重新分页（`currentOffset` 语义不变，不重置）。
private func applyContainerSize(
    _ size: CGSize,
    to state: inout ReaderFeature.State,
    using paginationService: PaginationService
) {
    guard state.config.containerSize != size else { return }
    state.config.containerSize = size
    repaginate(&state, using: paginationService)
}

// 相邻章的预加载、作废与换章迁移（两个方向逐条镜像）都在
// `ReaderFeature+ChapterTransition.swift`：本文件已贴着 `file_length` 600 的线。

/// 按当前 config 重排当前章**与相邻两章**。
///
/// 相邻章必须与当前章同一份 config（B0-2 几何契约）：换章后 `config` 不变，
/// 预加载的分页才对得上渲染盒。改了设置却只重排当前章，会让全景图 `±1` 格上
/// 那一页（以及换章后的第一页 / 最后一页）按旧排版切 —— 与屏幕上的盒子错位。
private func repaginate(
    _ state: inout ReaderFeature.State,
    using paginationService: PaginationService
) {
    state.pages = paginationService.paginate(state.displayText, state.config)
    if !state.nextText.isEmpty {
        state.nextPages = paginationService.paginate(state.nextDisplayText, state.config)
    }
    if !state.previousText.isEmpty {
        state.previousPages = paginationService.paginate(state.previousDisplayText, state.config)
    }
}
