import ComposableArchitecture
import Foundation
@testable import NovelCore
import NovelEngine
import XCTest

@MainActor
final class SiteFeatureTests: XCTestCase {
    func test拉取成功合并进列表且互斥去重() async throws {
        let settings = SiteSettings(
            navigationURL: "https://example.com",
            hosts: [SiteEntry(value: "https://mirror001.com")]
        )
        let keptID = settings.hosts[0].id
        // 记录落盘：`siteStore.save` 是 `@Sendable` 闭包，不能直接改写捕获的 `var`
        // （Swift 6 下是 concurrently-executing code 里改捕获变量）。见文件末尾的记录器。
        // 预置初值 = 改造前那个「先用初始 settings 初始化、之后被落盘覆盖」的 `var` ⇒ 判据不变。
        let recorder = SiteSettingsRecorder(initial: settings)
        let store = TestStore(initialState: SiteFeature.State(settings: settings)) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { recorder.record($0) }
        }

        let entry = SiteEntry(value: "https://mirror001.com/", isFromNavigation: true)
        await store.send(.navigationSucceeded([entry])) {
            // mirror001 与已有条目规范化后相同 → 保留原 id，只更新标记。
            $0.settings.hosts = [
                SiteEntry(id: keptID, value: "https://mirror001.com", isFromNavigation: true),
            ]
            $0.discoveredHosts = [entry]
        }
        await store.finish()

        XCTAssertEqual(store.state.settings.hosts.count, 1)
        XCTAssertEqual(store.state.settings.hosts[0].id, keptID)
        XCTAssertTrue(store.state.settings.hosts[0].isFromNavigation)
        let saved = try XCTUnwrap(recorder.latest())
        XCTAssertEqual(saved.hosts.count, 1)
        XCTAssertEqual(
            SiteSettings.canonicalHostKey(saved.hosts[0].value),
            SiteSettings.canonicalHostKey("https://mirror001.com")
        )
    }

    func test新增host追加进列表() {
        var settings = SiteSettings(hosts: [SiteEntry(value: "https://one.example")])
        settings.upsertHost("https://two.example", isFromNavigation: true)

        XCTAssertEqual(settings.hosts.count, 2)
        XCTAssertEqual(
            SiteSettings.canonicalHostKey(settings.hosts[1].value),
            SiteSettings.canonicalHostKey("https://two.example")
        )
        XCTAssertTrue(settings.hosts[1].isFromNavigation)
    }

    func test删除选中host后回落到第一条() async throws {
        let first = SiteEntry(value: "https://one.example")
        let second = SiteEntry(value: "https://two.example")
        let settings = SiteSettings(hosts: [first, second], currentHostID: second.id)
        // 同前一个用例：预置初值 ⇒ 判据与改造前逐字一致。
        let recorder = SiteSettingsRecorder(initial: settings)
        let store = TestStore(initialState: SiteFeature.State(settings: settings)) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { recorder.record($0) }
        }

        await store.send(.deleteHost(second.id)) {
            $0.settings.hosts = [first]
            $0.settings.currentHostID = first.id
        }
        await store.finish()

        let saved = try XCTUnwrap(recorder.latest())
        XCTAssertEqual(saved.currentHostID, first.id)
    }

    func test设置JSON往返保留导航地址与host() throws {
        var settings = SiteSettings(
            navigationURL: "https://example.com",
            hosts: [
                SiteEntry(value: "https://one.example"),
                SiteEntry(value: "https://two.example", isFromNavigation: true),
            ],
            currentHostID: nil
        )
        settings.normalize()

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SiteSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.navigationURL, "https://example.com")
        XCTAssertEqual(decoded.hosts.count, 2)
    }

    func test默认端口归一后互斥合并() {
        var settings = SiteSettings(
            hosts: [
                SiteEntry(value: "https://same.example:443"),
                SiteEntry(value: "https://same.example"),
            ]
        )

        settings.normalize()

        XCTAssertEqual(settings.hosts.count, 1)
    }

    // MARK: - H5：导航地址「编辑」与「落盘」分离

    func test逐按键编辑导航地址不落盘提交才落盘() async {
        // 「落盘了几次、内容是什么」由记录器承载（不能直接 append 捕获的 `var`，见文件末尾）。
        let recorder = SiteSettingsRecorder()
        let store = TestStore(initialState: SiteFeature.State()) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { recorder.record($0) }
        }

        // 逐按键只改内存：不落盘、不重配引擎（H5 的核心断言）。
        await store.send(.setNavigationURL("https")) {
            $0.settings.navigationURL = "https"
        }
        await store.send(.setNavigationURL("https://one.example")) {
            $0.settings.navigationURL = "https://one.example"
        }
        await store.finish()
        XCTAssertTrue(recorder.all().isEmpty, "逐按键不应触发落盘（H5）")

        // 带首尾空白的中间态同样不落盘。
        await store.send(.setNavigationURL("  https://one.example  ")) {
            $0.settings.navigationURL = "  https://one.example  "
        }
        await store.finish()
        XCTAssertTrue(recorder.all().isEmpty, "编辑中间态不应触发落盘")

        // 提交时才落盘一次，并在这一层去掉首尾空白。
        await store.send(.commitNavigationURL) {
            $0.settings.navigationURL = "https://one.example"
        }
        await store.finish()
        XCTAssertEqual(recorder.all().count, 1, "提交应恰好落盘一次")
        XCTAssertEqual(recorder.all().last?.navigationURL, "https://one.example")
    }

    func test清空导航地址不被拦截由拉取给出提示() async {
        // 同上一个用例：落盘记录由记录器承载（见文件末尾）。
        let recorder = SiteSettingsRecorder()
        let store = TestStore(
            initialState: SiteFeature.State(
                settings: SiteSettings(navigationURL: "https://example.com")
            )
        ) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { recorder.record($0) }
        }

        // 清空是合法编辑（=「未配置导航地址」），不再被「导航地址不能为空。」拦下。
        await store.send(.setNavigationURL("")) {
            $0.settings.navigationURL = ""
        }
        await store.send(.commitNavigationURL)
        await store.finish()
        XCTAssertEqual(recorder.all().last?.navigationURL, "")

        // 空地址点拉取 → 明确提示，且不发请求、不进 loading。
        await store.send(.fetchNavigationTapped) {
            $0.notice = "请先填写导航地址。"
        }
        await store.finish()
        XCTAssertFalse(store.state.isFetchingNavigation)
    }

    // MARK: - 域名区默认收起（收起态只展示当前选中的 host，展开入口仍在）

    func test默认收起且切换可往返() async {
        let store = TestStore(initialState: SiteFeature.State()) {
            SiteFeature()
        }

        XCTAssertFalse(store.state.isHostListExpanded, "域名区默认收起")

        await store.send(.toggleHostList) {
            $0.isHostListExpanded = true
        }
        await store.send(.toggleHostList) {
            $0.isHostListExpanded = false
        }
        await store.finish()
    }

    func test拉取成功后不自动展开() async {
        let existing = SiteEntry(value: "https://example.com")
        let store = TestStore(
            initialState: SiteFeature.State(settings: SiteSettings(hosts: [existing]))
        ) {
            SiteFeature()
        }

        let entry = SiteEntry(value: "https://example.com/", isFromNavigation: true)
        await store.send(.navigationSucceeded([entry])) {
            // 规范化后与已有条目相同 → 保留原 id，只更新「导航发现」标记。
            $0.settings.hosts = [
                SiteEntry(id: existing.id, value: "https://example.com", isFromNavigation: true),
            ]
            $0.discoveredHosts = [entry]
        }
        await store.finish()

        XCTAssertFalse(store.state.isHostListExpanded, "拉取成功后不应把域名区强制展开")
        XCTAssertEqual(store.state.settings.currentHost?.value, "https://example.com")
    }
}

/// 记录站点设置落盘调用，供 reducer 测试断言。
///
/// ## 为什么不能直接改写捕获的 `var`
/// `SiteStore.save` 是 `@Sendable (SiteSettings) async -> Void`（在后台执行）⇒ 在闭包里改写
/// 外面捕获的 `var`，Swift 6 下是「mutation of captured var in concurrently-executing code」。
/// 可变状态因此改由带锁的记录器承载。
///
/// ## 为什么用锁封装而不是 actor
/// 照本仓既有先例 `ReaderFeatureTests` 的 `SettingsRecorder`（同样是「记录 settings 落盘」）：
/// 锁封装让**断言侧保持同步读**（`latest()` / `all()`），用例体不必为了读记录到处加 `await`，
/// 断言的写法形状与改造前一致。`NSLock` 保护全部可变状态 ⇒ `@unchecked Sendable` 成立。
private final class SiteSettingsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SiteSettings]

    /// - Parameter initial: 预置一条「已落盘」记录。
    ///
    /// 传它 = 改造前那个「先用初始 settings 初始化、之后被落盘覆盖」的 `var`：即使一次都没
    /// 落盘，断言也读得到初始值 ⇒ 判据逐字不变（不因为换了承载方式而变严）。
    init(initial: SiteSettings? = nil) {
        if let initial {
            records = [initial]
        } else {
            records = []
        }
    }

    func record(_ settings: SiteSettings) {
        lock.lock()
        defer { lock.unlock() }
        records.append(settings)
    }

    /// 最后一次落盘值（无记录时为 `nil`）。
    func latest() -> SiteSettings? {
        lock.lock()
        defer { lock.unlock() }
        return records.last
    }

    /// 全部落盘记录（按发生顺序）。
    func all() -> [SiteSettings] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
