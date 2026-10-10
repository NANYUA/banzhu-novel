import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 阅读页 reducer 测试。
///
/// 分页桩 `FakeMeasuring` 的宽预算**由 `configuration` 推导**（见文件末尾的
/// `fakeWidthBudget`）：默认配置（320×480 / 字号 17 / 页边距 24）→ 预算 10，
/// 中文 2 宽 → 每页 5 字。改设置因此会**真的重排 `pages`**，而不是空转。
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
                Paginator(measurer: FakeMeasuring(widthBudget: fakeWidthBudget(for: config)))
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

    /// 🔴 数据契约：`currentOffset` 落在**页中间**时，`nextPage` 仍推进到下一页起点。
    ///
    /// 页中间的 offset 在生产里由「改字号 / 行距 / 页边距后重新分页」产生：
    /// `configChanged` 只重排 `pages`、不把 `currentOffset` 吸附到页首，
    /// 原页首于是可能落进新页的中间（见 ReaderFeature.swift 的 configChanged 分支）。
    /// 测试里已无改 offset 的 action（`jumpToOffset` 随滚动链路一起删除），
    /// 所以按它原先的语义（纯赋值）在初始状态里给出 offset = 3。
    func test页中间offset仍能翻到下一页() async {
        var initial = ReaderFeature.State(
            chapterPath: "/1/1.html",
            text: Self.sampleText,
            currentOffset: 3
        )
        // 与 loadSample 同一套确定性分页：10 字、每页 5 字
        initial.pages = [
            PageRange(location: 0, length: 5),
            PageRange(location: 5, length: 5),
        ]
        XCTAssertFalse(initial.pages.contains { $0.location == 3 }, "前置条件：3 必须落在页中间")
        let store = TestStore(initialState: initial) {
            ReaderFeature()
        }

        // 3 在第 0 页（0..<5）的中间 → 下一页起点是第 1 页的 5，而不是 3 + 5 = 8
        await store.send(.nextPage) {
            $0.currentOffset = 5
        }
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 5)
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

// MARK: - 配置变化 → 重新分页

/// 这几条放在 extension 里是有意的：`ReaderFeatureTests` 的类体已逼近 SwiftLint
/// `type_body_length` 的 250 行 warning 线（CI `--strict` 下 warning 即失败），
/// 而 extension **不计入**该指标（既有先例见下方「阅读设置持久化」）。
@MainActor extension ReaderFeatureTests {
    /// 校准点：默认配置必须推出宽预算 10 —— 本文件所有「每页 5 字」的期望都锚在这。
    ///
    /// 桩的预算改为由 config 推导后，这条就是**默认值护栏**：谁动了
    /// `ReaderFeature.State` 的默认 config 或推导系数，它会立刻红，
    /// 而不是让一批期望值莫名其妙地一起失败。
    func test默认配置推出宽预算十() {
        let config = ReaderFeature.State(chapterPath: "/1/1.html").config
        XCTAssertEqual(fakeWidthBudget(for: config), 10, "默认配置必须推出预算 10")
    }

    /// 🔴 数据契约：改配置**真的重新分页**，且 currentOffset 不丢（重排后仍能定位）。
    func test改配置重新分页且offset不丢() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.send(.nextPage) { $0.currentOffset = 5 }

        let pagesBefore = store.state.pages
        XCTAssertEqual(
            pagesBefore,
            [PageRange(location: 0, length: 5), PageRange(location: 5, length: 5)],
            "前置条件：改配置前每页 5 字（预算 10）"
        )
        XCTAssertEqual(store.state.currentPageIndex, 1, "前置条件：offset 5 是第 1 页页首")

        // 改配置：容器变宽 320 → 400，净宽 272 → 352，预算 10 → 13，每页 5 字 → 6 字。
        // 页边界必须真的变，否则这条用例里的「重新分页」就是空转。
        let sixPerPage = [PageRange(location: 0, length: 6), PageRange(location: 6, length: 4)]
        await store.send(.configChanged(PaginationConfiguration(
            containerSize: CGSize(width: 400, height: 480)
        ))) {
            $0.config.containerSize = CGSize(width: 400, height: 480)
            $0.pages = sixPerPage
        }
        await store.finish()

        XCTAssertNotEqual(store.state.pages, pagesBefore, "改配置后必须真的重新分页")
        XCTAssertEqual(store.state.pages, sixPerPage, "重排后页边界应随新预算变化")
        XCTAssertEqual(store.state.currentOffset, 5, "改配置后 offset 不应丢")
        // offset 5 在旧分页里是第 1 页页首，重排后落进第 0 页（0..<6）中间 ——
        // 仍能由 offset 反查出所在页，证明「重排后定位」不是靠页码。
        XCTAssertEqual(store.state.currentPageIndex, 0, "重排后 offset 仍能定位到所在页")
    }

    /// 外观类设置只更新配置，不触发重新分页，offset 同样不丢。
    func test改外观设置保留分页和offset() async {
        let store = makeStore(text: Self.sampleText) { _ in Self.sampleText }
        await loadSample(into: store)
        await store.send(.nextPage) { $0.currentOffset = 5 }

        var appearance = store.state.config
        appearance.backgroundStyle = .black
        appearance.customBackgroundColorDark = ReadingColor(red: 0.08, green: 0.08, blue: 0.1)
        appearance.appearanceMode = .dark

        await store.send(.configChanged(appearance)) {
            $0.config.backgroundStyle = .black
            $0.config.customBackgroundColorDark = ReadingColor(red: 0.08, green: 0.08, blue: 0.1)
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
}

// MARK: - 阅读设置持久化

@MainActor extension ReaderFeatureTests {
    /// 打开阅读页时读取持久化设置：配置与预缓存章数一起恢复。
    ///
    /// `pageTurnMode` 已收敛为单一取值（`.slide`），无法再作为「设置是否被恢复」的证据，
    /// 改用新增的暗色自定义背景色承担这个覆盖点。
    func test读取保存设置恢复() async {
        let saved = ReadingSettings(
            fontSize: 20,
            lineSpacing: 8,
            customBackgroundColorDark: ReadingColor(red: 0.12, green: 0.12, blue: 0.14),
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
        // 容器变宽 320 → 400（净宽 272 → 352，预算 10 → 13）→ 页边界随之重排。
        await store.send(.loadSavedSettings(CGSize(width: 400, height: 600))) {
            $0.config.containerSize = CGSize(width: 400, height: 600)
            $0.pages = [
                PageRange(location: 0, length: 6),
                PageRange(location: 6, length: 4),
            ]
        }
        // 恢复的字号 20 参与推导：352 / (20 × 1.6) = 11 → 每页 5 字，页边界再变一次。
        await store.receive(.settingsLoaded(saved, CGSize(width: 400, height: 600))) {
            $0.config.containerSize = CGSize(width: 400, height: 600)
            $0.config.fontSize = 20
            $0.config.lineSpacing = 8
            $0.config.customBackgroundColorDark = ReadingColor(red: 0.12, green: 0.12, blue: 0.14)
            $0.precacheCount = 5
            $0.pages = [
                PageRange(location: 0, length: 5),
                PageRange(location: 5, length: 5),
            ]
        }
        await store.finish()
        XCTAssertEqual(store.state.config.fontSize, 20)
        XCTAssertEqual(
            store.state.config.customBackgroundColorDark,
            ReadingColor(red: 0.12, green: 0.12, blue: 0.14)
        )
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
            // 尺寸变化 → 预算 10 → 13 → 页边界真的重排（不只是 config 变了）
            $0.pages = [
                PageRange(location: 0, length: 6),
                PageRange(location: 6, length: 4),
            ]
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
            // 字号 17 → 22：272 / (22 × 1.6) ≈ 7.7 → 预算 8 → 每页 4 字 → 3 页
            $0.pages = [
                PageRange(location: 0, length: 4),
                PageRange(location: 4, length: 4),
                PageRange(location: 8, length: 2),
            ]
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

/// 由分页配置推导 `FakeMeasuring` 的宽预算 —— 让「改设置」在测试里**真的**改变分页。
///
/// ## 为什么需要
/// 此前 `makeStore` 把预算钉死成 10，`FakeMeasuring` 又丢弃 `configuration`，
/// 于是改容器 / 字号 / 行距 / 页边距都改不动 `pages`，
/// 「改配置 → 重新分页」的用例其实是空转（只验证了 offset 不丢）。
///
/// ## 映射
/// `f(config) = max(1, round(净宽 / (fontSize × 1.6)))`，
/// 净宽 = `containerSize.width - inset.leading - inset.trailing`。
///
/// 与 `PaginatorTests` 同一思路：宽预算就是「容器 / 字号」的代理，
/// 容器变宽或字号变小 → 预算变大 → 每页字数变多。
///
/// ## 校准点：默认配置必须推出 10
/// 本文件绝大多数期望都锚在「默认配置 → 预算 10 → 每页 5 个中文」。
/// 默认配置取自 `ReaderFeature.State`（`containerSize = 320×480`、`fontSize = 17`、
/// `inset = PageInset()` 即左右各 24）：净宽 `320 - 24 - 24 = 272`，
/// `272 / (17 × 1.6) = 272 / 27.2 = 10` —— 正好 10，既有期望因此全部成立。
/// 系数 1.6 正是从这个校准点反推出来的（`272 / 17 / 10 = 1.6`），不是另挑的魔数。
///
/// 取整用 `rounded()` 而不是截断：`17 × 1.6` 在二进制浮点下是 27.200000000000003，
/// 截断会把 10 变成 9，本文件所有「每页 5 字」的期望会集体变红。
private func fakeWidthBudget(for configuration: PaginationConfiguration) -> Int {
    let netWidth = configuration.containerSize.width
        - configuration.inset.leading
        - configuration.inset.trailing
    // 字号下限 1：除零会得到 ∞，`Int(∞)` 直接崩
    let lineHeight = max(configuration.fontSize, 1) * 1.6
    let budget = Int((netWidth / lineHeight).rounded())
    return max(1, budget)
}
