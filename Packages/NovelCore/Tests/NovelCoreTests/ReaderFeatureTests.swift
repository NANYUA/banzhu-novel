import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 阅读页 reducer 测试。
///
/// 用 `FakeMeasuring`（宽预算 10，中文 2 宽 → 每页约 5 字）确定性分页，
/// 钉住翻页和 characterOffset 数据契约。
@MainActor
final class ReaderFeatureTests: XCTestCase {
    /// 样本正文：10 个中文，宽预算 10 → 每页 5 字 → 2 页
    private static let sampleText = "一二三四五六七八九十"

    private func makeStore(
        text: String,
        loader: @escaping @Sendable (String) async throws -> String,
        progress: @escaping @Sendable (String, Int, Date) async throws -> Void = { _, _, _ in },
        cache: @escaping @Sendable (String, String, Int) async -> Void = { _, _, _ in },
        settingsStore: ReadingSettingsStore? = nil
    ) -> TestStore<ReaderFeature.State, ReaderFeature.Action> {
        TestStore(initialState: ReaderFeature.State(chapterPath: "/1/1.html")) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = loader
            $0.readingProgressStore.markRead = progress
            $0.chapterCacheStore.cacheCurrentAndFollowing = cache
            $0.paginationService.paginate = { text, config in
                Paginator(measurer: FakeMeasuring(widthBudget: 10))
                    .paginate(text: text, configuration: config)
            }
            if let settingsStore {
                $0.readingSettingsStore = settingsStore
            }
        }
    }

    /// 公共前导：加载样本 → 断言分页成 2 页、offset 归零。
    ///
    /// `send`/`receive` 都改了状态，必须带断言闭包，
    /// 否则 TestStore 会报「State was not expected to change」。
    private func loadSample(into store: TestStore<ReaderFeature.State, ReaderFeature.Action>) async {
        await store.send(.loadChapter("/1/1.html")) {
            $0.chapterPath = "/1/1.html"
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded(Self.sampleText)) {
            $0.text = Self.sampleText
            $0.isLoading = false
            // 10 字，每页 5 字 → 2 页：page0 = {0,5}, page1 = {5,5}
            $0.pages = [
                PageRange(location: 0, length: 5),
                PageRange(location: 5, length: 5),
            ]
            $0.currentOffset = 0
        }
    }

    // MARK: - 测试

    /// 每页 5 个中文：10 字 = 2 页，每页 range 正确
    func test加载后分页正确() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.finish()
        XCTAssertEqual(store.state.pages.count, 2)
    }

    /// 下一页：offset 从 0 → 5（第二页起点）
    func test下一页移动offset() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)

        await store.send(.nextPage) {
            $0.currentOffset = 5
        }
        await store.finish()
    }

    /// 上一页：从第二页回到第一页
    func test上一页移动offset() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.send(.nextPage) { $0.currentOffset = 5 }

        await store.send(.prevPage) {
            $0.currentOffset = 0
            $0.pageTurnDirection = .backward
        }
        await store.finish()
    }

    /// 最后一页再下一页：不越界
    func test最后一页下一页不动() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.send(.nextPage) { $0.currentOffset = 5 }

        // 已在最后一页（第 2 页），再下一页无变化
        await store.send(.nextPage)
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 5)
    }

    /// 第一页上一页：不动
    func test第一页上一页不动() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)

        await store.send(.prevPage)
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 0)
    }

    /// jumpToOffset：跳到一个位置，随后 nextPage 从那里继续
    func test跳转到指定offset() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)

        await store.send(.jumpToOffset(3)) {
            $0.currentOffset = 3
        }
        // offset=3 在第 0 页（0..<5），next 去第 1 页（5）
        await store.send(.nextPage) {
            $0.currentOffset = 5
        }
        await store.finish()
    }

    /// jumpToOffset 越界 clamp
    func test跳转越界clamp() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)

        await store.send(.jumpToOffset(999)) {
            $0.currentOffset = 10 // 文本 10 字符，clamp 到 10
        }
        await store.finish()
    }

    /// 🔴 数据契约：改配置重新分页，但 currentOffset 不丢
    func test改配置重新分页且offset不丢() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.send(.nextPage) { $0.currentOffset = 5 }

        // 改配置（容器尺寸变 → 重新分页，页数可能变）
        await store.send(.configChanged(PaginationConfiguration(
            containerSize: CGSize(width: 400, height: 480)
        ))) {
            $0.config.containerSize = CGSize(width: 400, height: 480)
        }
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 5, "改配置后 offset 不应丢")
    }

    /// 外观类设置只更新配置，不触发重新分页，offset 同样不丢。
    func test改外观设置保留分页和offset() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.send(.nextPage) { $0.currentOffset = 5 }

        var appearance = store.state.config
        appearance.backgroundStyle = .black
        appearance.pageTurnMode = .scroll
        appearance.appearanceMode = .dark

        await store.send(.configChanged(appearance)) {
            $0.config.backgroundStyle = .black
            $0.config.pageTurnMode = .scroll
            $0.config.appearanceMode = .dark
        }
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 5)
        XCTAssertEqual(
            store.state.pages,
            [
                PageRange(location: 0, length: 5),
                PageRange(location: 5, length: 5),
            ]
        )
    }

    /// 加载失败：errorMessage 记录，isLoading 结束
    func test加载失败() async {
        struct LoadErr: Error, LocalizedError {
            var errorDescription: String? {
                "网络错误"
            }
        }
        let store = makeStore(text: "") { _ in throw LoadErr() }

        await store.send(.loadChapter("/1/1.html")) {
            $0.chapterPath = "/1/1.html"
            $0.isLoading = true
        }
        await store.receive(.loadFailed("网络错误")) {
            $0.isLoading = false
            $0.errorMessage = "网络错误"
        }
        await store.finish()
    }

    /// 空文本：pages 空，翻页无效果
    func test空文本() async {
        let store = makeStore(text: "") { _ in "" }
        await store.send(.loadChapter("/1/1.html")) {
            $0.chapterPath = "/1/1.html"
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded("")) {
            $0.text = ""
            $0.isLoading = false
            $0.pages = []
            $0.currentOffset = 0
        }

        await store.send(.nextPage)
        await store.send(.prevPage)
        await store.finish()
        XCTAssertTrue(store.state.pages.isEmpty)
        XCTAssertEqual(store.state.currentOffset, 0)
    }

    func test章节名参与第一页分页() async {
        let displayText = "第一章 开始\n\n" + Self.sampleText
        let expectedPages = Paginator(measurer: FakeMeasuring(widthBudget: 10)).paginate(
            text: displayText,
            configuration: ReaderFeature.State(chapterPath: "/1/1.html").config
        )
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await store.send(.loadChapterWithName("/1/1.html", "第一章 开始")) {
            $0.chapterPath = "/1/1.html"
            $0.chapterName = "第一章 开始"
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded(Self.sampleText)) {
            $0.text = Self.sampleText
            $0.isLoading = false
            $0.pages = expectedPages
            $0.currentOffset = 0
        }
        await store.finish()
        XCTAssertTrue(store.state.displayText.hasPrefix("第一章 开始\n\n"))
        XCTAssertFalse(store.state.pages.isEmpty)
    }

    /// 内容加载成功后必须写入阅读进度，供书架排序与 LRU 淘汰使用。
    func test加载成功写入阅读进度() async {
        let recorder = ReadRecorder()
        let store = makeStore(text: Self.sampleText) { _ in
            Self.sampleText
        } progress: { path, offset, date in
            await recorder.record(path: path, offset: offset, date: date)
        }

        await loadSample(into: store)
        await store.finish()

        let records = await recorder.allRecords()
        XCTAssertEqual(records.map(\.path), ["/1/1.html"])
        XCTAssertEqual(records.first?.offset, 0)
        XCTAssertNotNil(records.first?.date)
    }

    /// 正文加载成功后必须触发当前章与后续章节的自动缓存。
    func test加载成功触发自动缓存() async {
        let recorder = CacheRecorder()
        let store = makeStore(text: Self.sampleText) { _ in
            Self.sampleText
        } cache: { path, text, count in
            await recorder.record(path: path, text: text, count: count)
        }

        await loadSample(into: store)
        await store.finish()

        let records = await recorder.allRecords()
        XCTAssertEqual(records.map(\.path), ["/1/1.html"])
        XCTAssertEqual(records.first?.text, Self.sampleText)
        XCTAssertEqual(records.first?.count, 3)
    }

    /// 预缓存章数会 clamp 到 0...20，并使用最新值触发后续章节缓存。
    func test修改预缓存章数并用于自动缓存() async {
        let recorder = CacheRecorder()
        let store = makeStore(text: Self.sampleText) { _ in
            Self.sampleText
        } cache: { path, text, count in
            await recorder.record(path: path, text: text, count: count)
        }

        await store.send(.precacheCountChanged(-1)) {
            $0.precacheCount = 0
        }
        await store.send(.precacheCountChanged(99)) {
            $0.precacheCount = 20
        }
        await loadSample(into: store)
        await store.finish()

        let records = await recorder.allRecords()
        XCTAssertEqual(records.first?.count, 20)
    }
}

// MARK: - 阅读设置持久化

@MainActor extension ReaderFeatureTests {
    /// 打开阅读页时读取持久化设置：配置与预缓存章数一起恢复。
    func test读取保存设置恢复() async {
        let saved = ReadingSettings(
            fontSize: 20,
            lineSpacing: 8,
            pageTurnMode: .tap,
            precacheCount: 5
        )
        let store = makeStore(
            text: Self.sampleText,
            loader: { _ in Self.sampleText },
            settingsStore: ReadingSettingsStore(
                load: { saved },
                save: { _ in }
            )
        )

        await loadSample(into: store)
        // reducer 现在会立即应用真实容器尺寸（比例修复的一部分），所以 send 要带断言。
        await store.send(.loadSavedSettings(CGSize(width: 400, height: 600))) {
            $0.config.containerSize = CGSize(width: 400, height: 600)
        }
        await store.receive(.settingsLoaded(saved, CGSize(width: 400, height: 600))) {
            $0.config.containerSize = CGSize(width: 400, height: 600)
            $0.config.fontSize = 20
            $0.config.lineSpacing = 8
            $0.config.pageTurnMode = .tap
            $0.precacheCount = 5
        }
        await store.finish()
        XCTAssertEqual(store.state.config.fontSize, 20)
        XCTAssertEqual(store.state.config.pageTurnMode, .tap)
        XCTAssertEqual(store.state.precacheCount, 5)
    }

    /// 没有持久化设置时：除容器尺寸外保持默认，且不产生恢复动作。
    /// 🔴 容器尺寸必须用真实布局尺寸，否则分页按 320×480 算，正文只占屏幕一部分。
    func test无保存设置时容器尺寸用真实布局尺寸() async {
        let store = makeStore(
            text: "",
            loader: { _ in "" },
            settingsStore: ReadingSettingsStore(
                load: { nil },
                save: { _ in }
            )
        )

        await store.send(.loadSavedSettings(CGSize(width: 400, height: 600))) {
            $0.config.containerSize = CGSize(width: 400, height: 600)
        }
        await store.finish()
        XCTAssertEqual(
            store.state.config,
            PaginationConfiguration(containerSize: CGSize(width: 400, height: 600))
        )
        XCTAssertEqual(store.state.precacheCount, ReaderFeature.defaultPrecacheCount)
    }

    /// 旋转 / 分屏 / 换机型：尺寸变化要重新分页，但 currentOffset 不丢。
    func test容器尺寸变化重新分页且offset不丢() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.send(.nextPage) { $0.currentOffset = 5 }

        await store.send(.containerSizeChanged(CGSize(width: 400, height: 600))) {
            $0.config.containerSize = CGSize(width: 400, height: 600)
        }
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 5, "尺寸变化后 offset 不应丢")
    }

    /// 修改阅读配置后必须持久化（含预缓存章数）。
    func test修改配置自动保存() async {
        let recorder = SettingsRecorder()
        let store = makeStore(
            text: Self.sampleText,
            loader: { _ in Self.sampleText },
            settingsStore: ReadingSettingsStore(
                load: { nil },
                save: { settings in recorder.record(settings) }
            )
        )

        await loadSample(into: store)
        var next = store.state.config
        next.fontSize = 22
        next.backgroundStyle = .black
        await store.send(.configChanged(next)) {
            $0.config.fontSize = 22
            $0.config.backgroundStyle = .black
        }
        await store.send(.precacheCountChanged(7)) {
            $0.precacheCount = 7
        }
        await store.finish()

        let saved = recorder.latest()
        XCTAssertEqual(saved?.fontSize, 22)
        XCTAssertEqual(saved?.backgroundStyle, .black)
        XCTAssertEqual(saved?.precacheCount, 7)
    }
}

/// 记录阅读进度调用，供 reducer 测试断言。
private actor ReadRecorder {
    struct Reading: Sendable {
        let path: String
        let offset: Int
        let date: Date
    }

    private var records: [Reading] = []

    func record(path: String, offset: Int, date: Date) {
        records.append(Reading(path: path, offset: offset, date: date))
    }

    func allRecords() -> [Reading] {
        records
    }
}

/// 记录自动缓存调用，供 reducer 测试断言。
private actor CacheRecorder {
    struct Request: Sendable {
        let path: String
        let text: String
        let count: Int
    }

    private var records: [Request] = []

    func record(path: String, text: String, count: Int) {
        records.append(Request(path: path, text: text, count: count))
    }

    func allRecords() -> [Request] {
        records
    }
}

/// 记录阅读设置保存调用，供 reducer 测试断言。
private final class SettingsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latestSaved: ReadingSettings?

    func record(_ settings: ReadingSettings) {
        lock.lock()
        defer { lock.unlock() }
        latestSaved = settings
    }

    func latest() -> ReadingSettings? {
        lock.lock()
        defer { lock.unlock() }
        return latestSaved
    }
}
