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
            precacheCount: Int = ReaderFeature.defaultPrecacheCount
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
        }

        /// 当前章节路径（如 `/49/49034/123.html`）
        public var chapterPath: String

        /// 当前章节名。第一页会作为纯文本标题参与统一分页。
        public var chapterName: String

        /// 本章正文本体
        public var text: String

        /// 渲染与分页使用的文本：章节名作为普通正文前缀。
        public var displayText: String {
            guard !chapterName.isEmpty else { return text }
            let normalizedTitle = chapterName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTitle.isEmpty else { return text }
            let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedText.hasPrefix(normalizedTitle) {
                return text
            }
            return normalizedTitle + "\n\n" + text
        }

        /// 标题前缀长度；持久化 characterOffset 时需要扣除。
        public var titlePrefixLength: Int {
            max(0, displayText.count - text.count)
        }

        /// 对外持久化的字符偏移，始终相对原始正文。
        public var progressOffset: Int {
            max(0, currentOffset - titlePrefixLength)
        }

        /// 分页配置。改了会触发重新分页
        public var config: PaginationConfiguration

        /// 🔴 阅读位置：字符偏移，**不是页码**。
        /// 改设置后靠它重新定位到同一处文字。
        public var currentOffset: Int

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

        /// 当前 offset 落在第几页。`-1` 表示还没分页（空文本）
        public var currentPageIndex: Int {
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
        /// 跳到指定字符偏移
        case jumpToOffset(Int)
        /// 分页配置变化（触发重算分页 + 按 offset 重新定位）
        case configChanged(PaginationConfiguration)
        /// 自动预缓存后续章节数变化
        case precacheCountChanged(Int)
        /// 从持久化恢复阅读设置
        case loadSavedSettings(CGSize)
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
                state.currentOffset = 0
                let chapterPath = state.chapterPath
                let progressStore = readingProgressStore
                let cacheStore = chapterCacheStore
                let precacheCount = state.precacheCount
                return .run { _ in
                    // 进度写入失败不应阻断阅读；书架排序与 LRU 会在下次成功时刷新。
                    try? await progressStore.markRead(chapterPath, 0, Date())
                    await cacheStore.cacheCurrentAndFollowing(chapterPath, text, precacheCount)
                }

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

            case let .jumpToOffset(offset):
                // clamp 到文本范围
                let maxOffset = max(0, state.displayText.count)
                state.currentOffset = min(max(0, offset), maxOffset)
                return saveProgress(
                    chapterPath: state.chapterPath,
                    offset: state.progressOffset,
                    store: readingProgressStore
                )

            case let .configChanged(newConfig):
                guard newConfig != state.config else { return .none }
                let shouldRepaginate = newConfig.affectsPagination(comparedTo: state.config)
                state.config = newConfig
                // 只有影响排版的设置才重新分页；背景色 / 翻页方式等直接生效。
                if shouldRepaginate {
                    state.pages = paginationService.paginate(state.displayText, newConfig)
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
                let settingsStore = readingSettingsStore
                return .run { send in
                    guard let settings = settingsStore.load() else { return }
                    await send(.settingsLoaded(settings, size))
                }

            case let .settingsLoaded(settings, size):
                let merged = settings.mergedConfiguration(containerSize: size)
                let shouldRepaginate = merged.affectsPagination(comparedTo: state.config)
                state.config = merged
                state.precacheCount = min(max(settings.precacheCount, 0), Self.maxPrecacheCount)
                if shouldRepaginate {
                    state.pages = paginationService.paginate(state.displayText, merged)
                }
                return .none
            }
        }
    }
}

private func saveProgress(
    chapterPath: String,
    offset: Int,
    store: ReadingProgressStore
) -> Effect<ReaderFeature.Action> {
    .run { _ in
        try? await store.markRead(chapterPath, offset, Date())
    }
}
