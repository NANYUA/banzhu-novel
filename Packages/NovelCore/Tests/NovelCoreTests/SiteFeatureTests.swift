import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

@MainActor
final class SiteFeatureTests: XCTestCase {
    func test拉取成功合并进列表且互斥去重() async {
        var settings = SiteSettings(
            navigationURL: "https://example.com",
            hosts: [SiteEntry(value: "https://mirror001.com")]
        )
        let keptID = settings.hosts[0].id
        let store = TestStore(initialState: SiteFeature.State(settings: settings)) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { saved in
                settings = saved
            }
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
        XCTAssertEqual(settings.hosts.count, 1)
        XCTAssertEqual(
            SiteSettings.canonicalHostKey(settings.hosts[0].value),
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

    func test删除选中host后回落到第一条() async {
        let first = SiteEntry(value: "https://one.example")
        let second = SiteEntry(value: "https://two.example")
        var settings = SiteSettings(hosts: [first, second], currentHostID: second.id)
        let store = TestStore(initialState: SiteFeature.State(settings: settings)) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { saved in
                settings = saved
            }
        }

        await store.send(.deleteHost(second.id)) {
            $0.settings.hosts = [first]
            $0.settings.currentHostID = first.id
        }
        await store.finish()

        XCTAssertEqual(settings.currentHostID, first.id)
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
        var saved: [SiteSettings] = []
        let store = TestStore(initialState: SiteFeature.State()) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { saved.append($0) }
        }

        // 逐按键只改内存：不落盘、不重配引擎（H5 的核心断言）。
        await store.send(.setNavigationURL("https")) {
            $0.settings.navigationURL = "https"
        }
        await store.send(.setNavigationURL("https://one.example")) {
            $0.settings.navigationURL = "https://one.example"
        }
        await store.finish()
        XCTAssertTrue(saved.isEmpty, "逐按键不应触发落盘（H5）")

        // 带首尾空白的中间态同样不落盘。
        await store.send(.setNavigationURL("  https://one.example  ")) {
            $0.settings.navigationURL = "  https://one.example  "
        }
        await store.finish()
        XCTAssertTrue(saved.isEmpty, "编辑中间态不应触发落盘")

        // 提交时才落盘一次，并在这一层去掉首尾空白。
        await store.send(.commitNavigationURL) {
            $0.settings.navigationURL = "https://one.example"
        }
        await store.finish()
        XCTAssertEqual(saved.count, 1, "提交应恰好落盘一次")
        XCTAssertEqual(saved.last?.navigationURL, "https://one.example")
    }

    func test清空导航地址不被拦截由拉取给出提示() async {
        var saved: [SiteSettings] = []
        let store = TestStore(
            initialState: SiteFeature.State(
                settings: SiteSettings(navigationURL: "https://example.com")
            )
        ) {
            SiteFeature()
        } withDependencies: {
            $0.siteRouter.configure = { _ in }
            $0.siteStore.save = { saved.append($0) }
        }

        // 清空是合法编辑（=「未配置导航地址」），不再被「导航地址不能为空。」拦下。
        await store.send(.setNavigationURL("")) {
            $0.settings.navigationURL = ""
        }
        await store.send(.commitNavigationURL)
        await store.finish()
        XCTAssertEqual(saved.last?.navigationURL, "")

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
