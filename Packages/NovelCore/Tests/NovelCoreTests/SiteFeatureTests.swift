import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

@MainActor
final class SiteFeatureTests: XCTestCase {
    func test拉取成功合并进列表且互斥去重() async {
        var settings = SiteSettings(
            navigationURL: "https://192.2.245.225",
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

        let entries = [
            SiteEntry(value: "https://mirror001.com/", isFromNavigation: true),
            SiteEntry(value: "https://mirror002.com", isFromNavigation: true),
        ]
        await store.send(.navigationSucceeded(entries)) {
            // mirror001 与已有条目规范化后相同 → 保留原 id，只更新标记。
            $0.settings.hosts = [
                SiteEntry(id: keptID, value: "https://mirror001.com", isFromNavigation: true),
                entries[1],
            ]
            $0.discoveredHosts = entries
            $0.isHostListExpanded = true
        }
        await store.finish()

        XCTAssertEqual(settings.hosts.count, 2)
        XCTAssertEqual(
            SiteSettings.canonicalHostKey(settings.hosts[0].value),
            SiteSettings.canonicalHostKey("https://mirror001.com")
        )
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
            navigationURL: "https://192.2.245.225",
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
        XCTAssertEqual(decoded.navigationURL, "https://192.2.245.225")
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
}
