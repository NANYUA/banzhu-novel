import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 下载设置持久化的锚点测试（owner 需求：下载设置里的改动要能被记住）。
///
/// ## 为什么值得单测
/// 失效模式是「每次启动都回到默认值」：用户改了设置、杀掉 App 重进又变回去，
/// 表现出来只是「设置没用」，极难归因。所以这里锁住四件事：
/// 真实 `UserDefaults` 往返、没存过返回 `nil`、坏数据不崩、reducer 确实落盘与恢复。
///
/// ## 隔离
/// 一律用独立 suite 的 `UserDefaults`（`UserDefaults(suiteName:)`），`tearDown` 里清干净 ——
/// **绝不碰 `.standard`**：那是真机 / 模拟器上用户的真实下载设置。
final class DownloadSettingsLiveTests: XCTestCase {
    /// 本用例建过的 suite 名，`tearDown` 统一清掉。
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    /// 隔离的 `UserDefaults`：独立 suite + 建时先清一次（防同进程上一次的残留）。
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "NovelCoreTests.downloadSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        suiteNames.append(suiteName)
        return defaults
    }

    /// ① 往返：`save` 之后 `load` 逐值相等。
    ///
    /// 两个字段都取**非默认值**（`true` / `.fast`），否则「恰好等于默认值」也能蒙混过关。
    func test保存后能逐值读回() throws {
        let defaults = try makeIsolatedDefaults()
        let settings = DownloadSettings(allowsCellular: true, speed: .fast)

        DownloadSettingsLive.save(settings, defaults: defaults)

        let loaded = try XCTUnwrap(DownloadSettingsLive.load(defaults: defaults))
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.allowsCellular, settings.allowsCellular)
        XCTAssertEqual(loaded.speed, settings.speed)
    }

    /// ② 没存过 ⇒ `nil`（**不是**一份默认值）。
    ///
    /// 默认值只有 `DownloadFeature.State` 一个真相源；这里再给一份会让首装默认值出现两处定义。
    func test没有存过时返回空而不是默认值() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(defaults.data(forKey: DownloadSettingsLive.storageKey))
        XCTAssertNil(DownloadSettingsLive.load(defaults: defaults))
    }

    /// ③ 坏数据 ⇒ `nil` 且不崩。两种坏法都锁：不是 JSON、是 JSON 但字段类型不对。
    func test数据损坏时返回空且不崩() throws {
        let defaults = try makeIsolatedDefaults()

        defaults.set(Data("不是 JSON".utf8), forKey: DownloadSettingsLive.storageKey)
        XCTAssertNil(DownloadSettingsLive.load(defaults: defaults))

        defaults.set(Data(#"{"allowsCellular":"yes"}"#.utf8), forKey: DownloadSettingsLive.storageKey)
        XCTAssertNil(DownloadSettingsLive.load(defaults: defaults))
    }

    /// ④ 存储键必须带版本号（`<域>.<用途>.v<版本>`）：将来 schema 变更靠提版本让旧数据自然失效。
    ///
    /// 刻意钉死字面量：这是**存储契约**，不是被测系统的派生输出 —— 改 key 必须是有意识的决定。
    func test存储键带版本号() {
        XCTAssertEqual(DownloadSettingsLive.storageKey, "download.settings.v1")
    }
}

/// reducer 侧的落盘 / 恢复测试。
///
/// 单独一个文件而不是塞进 `DownloadFeatureTests`：那个类贴着 `type_body_length` 红线，
/// 且本组用例要往 `withDependencies` 里多注入一个 `downloadSettingsStore`。
@MainActor
final class DownloadSettingsReducerTests: XCTestCase {
    /// 本组自己的 `makeStore`：比共享夹具 `DownloadFeatureTestCase` 多注入一个设置桩。
    private func makeStore(
        settings: DownloadSettingsStore,
        queue: InMemoryDownloadQueueStore = InMemoryDownloadQueueStore(),
        initialState: DownloadFeature.State = DownloadFeature.State()
    ) -> TestStore<DownloadFeature.State, DownloadFeature.Action> {
        TestStore(initialState: initialState) {
            DownloadFeature()
        } withDependencies: {
            $0.downloadQueueStore = queue.dependency()
            $0.chapterDownloader.download = { _ in "" }
            $0.downloadSettingsStore = settings
        }
    }

    /// ① 改蜂窝开关 ⇒ 落盘**一次**，且传出的是改完之后的完整设置（含当时的速度档）。
    func test切换蜂窝开关会落盘() async {
        let recorder = DownloadSettingsRecorder()
        let initial = DownloadFeature.State()
        let store = makeStore(
            settings: DownloadSettingsStore(load: { nil }, save: { recorder.record($0) }),
            initialState: initial
        )

        await store.send(.setAllowsCellular(true)) {
            $0.allowsCellular = true
        }
        await store.finish()

        XCTAssertEqual(recorder.allSaved(), [
            DownloadSettings(allowsCellular: true, speed: initial.speed),
        ])
    }

    /// ② 改速率档位 ⇒ 落盘**一次**，且蜂窝开关按当时的值带上（不是硬编码 `false`）。
    func test切换速率档位会落盘() async {
        let recorder = DownloadSettingsRecorder()
        let initial = DownloadFeature.State(allowsCellular: true)
        let store = makeStore(
            settings: DownloadSettingsStore(load: { nil }, save: { recorder.record($0) }),
            initialState: initial
        )

        await store.send(.setSpeed(.fast)) {
            $0.speed = .fast
        }
        await store.finish()

        XCTAssertEqual(recorder.allSaved(), [
            DownloadSettings(allowsCellular: initial.allowsCellular, speed: .fast),
        ])
    }

    /// ③ 启动时读到已存设置 ⇒ 只覆盖那两个字段（整 State 比对 ⇒ 其它字段被顺手改掉会红）。
    func test启动时用已存设置覆盖状态() async {
        let saved = DownloadSettings(allowsCellular: true, speed: .fast)
        let store = makeStore(settings: DownloadSettingsStore(load: { saved }, save: { _ in }))

        await store.send(.task) {
            $0.isObservingNetwork = true
        }
        await store.receive(.loaded([]))
        await store.receive(.settingsLoaded(saved)) {
            $0.allowsCellular = saved.allowsCellular
            $0.speed = saved.speed
        }
        await store.finish()

        var expected = DownloadFeature.State()
        expected.isObservingNetwork = true
        expected.allowsCellular = saved.allowsCellular
        expected.speed = saved.speed
        XCTAssertEqual(store.state, expected)
    }

    /// ④ 没存过 ⇒ 保持 State 默认值，不报错也不提示。
    func test没有已存设置时保持默认值() async {
        let store = makeStore(settings: DownloadSettingsStore(load: { nil }, save: { _ in }))

        await store.send(.task) {
            $0.isObservingNetwork = true
        }
        await store.receive(.loaded([]))
        await store.finish()

        var expected = DownloadFeature.State()
        expected.isObservingNetwork = true
        XCTAssertEqual(store.state, expected)
        XCTAssertNil(store.state.notice)
    }

    /// ⑤ 不注入设置桩（既有测试的默认形态）⇒ 依赖是 no-op：
    /// 改设置不落盘也不崩，读取返回 `nil` 不会把用户刚改的值读回默认。
    func test未注入设置桩时依赖是空操作() async {
        let store = TestStore(initialState: DownloadFeature.State()) {
            DownloadFeature()
        } withDependencies: {
            $0.downloadQueueStore = InMemoryDownloadQueueStore().dependency()
            $0.chapterDownloader.download = { _ in "" }
        }

        await store.send(.setSpeed(.fast)) {
            $0.speed = .fast
        }
        await store.send(.task) {
            $0.isObservingNetwork = true
        }
        await store.receive(.loaded([]))
        await store.finish()

        var expected = DownloadFeature.State()
        expected.isObservingNetwork = true
        expected.speed = .fast
        XCTAssertEqual(store.state, expected)
    }
}

/// 记录下载设置保存调用，供 reducer 测试断言（跨 Effect 边界 ⇒ 加锁保证 `Sendable`）。
private final class DownloadSettingsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [DownloadSettings] = []

    func record(_ settings: DownloadSettings) {
        lock.lock()
        defer { lock.unlock() }
        saved.append(settings)
    }

    func allSaved() -> [DownloadSettings] {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }
}
