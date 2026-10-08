import ComposableArchitecture
@testable import NovelCore
import XCTest

@MainActor
final class SiteFeatureTests: XCTestCase {
    private actor Recorder {
        var saved: SiteSettings?
        var configured: SiteSettings?

        func save(_ settings: SiteSettings) {
            saved = settings
        }

        func configure(_ settings: SiteSettings) {
            configured = settings
        }

        func snapshot() -> (saved: SiteSettings?, configured: SiteSettings?) {
            (saved, configured)
        }
    }

    func test加载设置后立即同步引擎() async {
        let hostID = UUID()
        let settings = SiteSettings(
            hosts: [SiteEntry(id: hostID, value: "https://example.com")],
            currentHostID: hostID
        )
        let recorder = Recorder()
        let store = TestStore(initialState: SiteFeature.State()) {
            SiteFeature()
        } withDependencies: {
            $0.siteStore.load = { settings }
            $0.siteStore.save = { await recorder.save($0) }
            $0.siteRouter.configure = { await recorder.configure($0) }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.loaded(settings)) {
            $0.settings = settings
            $0.isLoading = false
        }
        await store.finish()

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.saved, settings)
        XCTAssertEqual(snapshot.configured, settings)
    }

    func test删除当前host后回落到第一个() async {
        let first = SiteEntry(value: "https://one.example")
        let second = SiteEntry(value: "https://two.example")
        let initial = SiteSettings(
            hosts: [first, second],
            currentHostID: second.id
        )
        let recorder = Recorder()
        let store = TestStore(initialState: SiteFeature.State(settings: initial)) {
            SiteFeature()
        } withDependencies: {
            $0.siteStore.save = { await recorder.save($0) }
            $0.siteRouter.configure = { await recorder.configure($0) }
        }

        await store.send(.deleteHost(second.id)) {
            $0.settings.hosts = [first]
            $0.settings.currentHostID = first.id
        }
        await store.finish()

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.saved?.hosts, [first])
        XCTAssertEqual(snapshot.configured?.currentHostID, first.id)
    }

    func test切换host与自动换host开关() async {
        let first = SiteEntry(value: "https://one.example")
        let second = SiteEntry(value: "https://two.example")
        let initial = SiteSettings(
            hosts: [first, second],
            currentHostID: first.id,
            autoSwitchHost: true
        )
        let store = TestStore(initialState: SiteFeature.State(settings: initial)) {
            SiteFeature()
        }

        await store.send(.selectHost(second.id)) {
            $0.settings.currentHostID = second.id
        }
        await store.send(.setAutoSwitch(false)) {
            $0.settings.autoSwitchHost = false
        }
        await store.send(.setVerificationStartTier(.first)) {
            $0.settings.verificationStartTier = .first
        }
        await store.finish()
    }

    func test设置可完整JSON往返() throws {
        let settings = SiteSettings(
            navigationURLs: [SiteEntry(value: "https://nav.example")],
            hosts: [SiteEntry(value: "https://host.example")],
            autoSwitchHost: false
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SiteSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.verificationStartTier, .second)
        XCTAssertEqual(decoded.currentNavigationURL, "https://nav.example")
        XCTAssertEqual(decoded.currentHost, "https://host.example")
    }

    func test导航发现的host与用户host分开保存() {
        var settings = SiteSettings(
            hosts: [SiteEntry(value: "https://user.example", source: .user)]
        )

        settings.recordHost("https://nav-one.example")
        settings.recordHost("https://nav-two.example")

        XCTAssertEqual(settings.userHosts.map(\.value), ["https://user.example"])
        XCTAssertEqual(
            settings.navigationHosts.map(\.value),
            ["https://nav-one.example", "https://nav-two.example"]
        )
        XCTAssertEqual(settings.currentHost, "https://nav-two.example")
    }

    func test旧数据缺失来源时默认归为用户host() throws {
        let data = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","value":"https://legacy.example"}"#
                .utf8
        )

        let entry = try JSONDecoder().decode(SiteEntry.self, from: data)

        XCTAssertEqual(entry.source, .user)
    }

    func test用户host与导航host重叠时合并来源() {
        let value = "https://same.example"
        let settings = SiteSettings(
            hosts: [
                SiteEntry(value: value, source: .user),
                SiteEntry(value: value, source: .navigation),
            ]
        )

        XCTAssertEqual(settings.hosts.count, 1)
        XCTAssertEqual(settings.hosts[0].sources, [.user, .navigation])
    }

    func test导航host上限会淘汰低优先级条目() {
        var unavailable = SiteEntry(value: "https://a.example", source: .navigation)
        unavailable.hostStatus = .unavailable
        var unknown = SiteEntry(value: "https://b.example", source: .navigation)
        unknown.hostStatus = .unknown
        let user = SiteEntry(value: "https://user.example", source: .user)

        let settings = SiteSettings(
            hosts: [user, unavailable, unknown],
            navigationHostLimit: 1
        )

        XCTAssertTrue(settings.hosts.contains(where: { $0.id == user.id }))
        XCTAssertTrue(settings.hosts.contains(where: { $0.id == unknown.id }))
        XCTAssertFalse(settings.hosts.contains(where: { $0.id == unavailable.id }))
    }

    func test导航连续失败进入冷却再冻结() {
        let nav = SiteEntry(value: "https://nav.example", source: .user)
        var settings = SiteSettings(navigationURLs: [nav])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        settings.recordNavigationFailure(id: nav.id, now: now)
        XCTAssertEqual(settings.navigationURLs[0].navigationStatus, .cooling)

        settings.recordNavigationFailure(id: nav.id, now: now)
        XCTAssertEqual(settings.navigationURLs[0].navigationStatus, .frozen)
    }

    func test删除重叠host的用户来源后降级为导航host() async {
        let entry = SiteEntry(
            value: "https://same.example",
            sources: [.user, .navigation]
        )
        let store = TestStore(
            initialState: SiteFeature.State(
                settings: SiteSettings(hosts: [entry])
            )
        ) {
            SiteFeature()
        }

        await store.send(.deleteHost(entry.id)) {
            $0.settings.hosts[0].sources = [.navigation]
        }
        await store.finish()
        XCTAssertEqual(store.state.settings.hosts[0].sources, [.navigation])
    }
}
