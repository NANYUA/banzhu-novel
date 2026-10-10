import Dependencies
import Foundation
import NovelEngine

/// 书城分类的落盘快照。
///
/// 引擎的 `ExploreCategory` 是冻结类型且**没有实现 `Codable`**，
/// 落盘只能另立一个可编解码的镜像类型 —— 不为一个缓存去改引擎。
struct ExploreCategorySnapshot: Codable, Equatable, Sendable {
    init(title: String, urlTemplate: String) {
        self.title = title
        self.urlTemplate = urlTemplate
    }

    init(_ category: ExploreCategory) {
        self.init(title: category.title, urlTemplate: category.urlTemplate)
    }

    var title: String

    /// 含 `{{page}}` 的路径模板。
    var urlTemplate: String

    /// 还原成引擎类型（`id` 由 `title` 推出，见 `ExploreCategory`）。
    var category: ExploreCategory {
        ExploreCategory(title: title, urlTemplate: urlTemplate)
    }
}

/// 书城分类读写依赖。
///
/// 与 `SiteStore` / `ReadingSettingsStore` 同理：reducer 不直接碰 `UserDefaults`，
/// 测试用 `withDependencies` 换成内存桩，断言的仍是完整状态迁移。
struct ExploreCategoryStore: Sendable {
    /// 没存过 / 解码失败 → `nil`（不抛不崩）；空数组同样视为「没缓存」。
    var load: @Sendable () async -> [ExploreCategory]?
    var save: @Sendable ([ExploreCategory]) async -> Void
}

extension DependencyValues {
    var exploreCategoryStore: ExploreCategoryStore {
        get { self[ExploreCategoryStoreKey.self] }
        set { self[ExploreCategoryStoreKey.self] = newValue }
    }

    private enum ExploreCategoryStoreKey: DependencyKey {
        static let liveValue = ExploreCategoryStore(
            load: { ExploreCategoryStoreLive.load() },
            save: { ExploreCategoryStoreLive.save($0) }
        )

        /// 测试默认值：无缓存、不落盘 —— 避免忘记注入桩的测试读写到真实 `UserDefaults`。
        static let testValue = ExploreCategoryStore(
            load: { nil },
            save: { _ in }
        )
    }
}

/// 真实实现：`UserDefaults` + JSON（照 `SiteStorePersistence` / `ReadingSettingsStore`）。
private enum ExploreCategoryStoreLive {
    private static let storageKey = "explore.categories.v1"

    static func load() -> [ExploreCategory]? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        guard let snapshots = try? JSONDecoder().decode([ExploreCategorySnapshot].self, from: data)
        else {
            return nil
        }
        return snapshots.map(\.category)
    }

    static func save(_ categories: [ExploreCategory]) {
        let snapshots = categories.map { ExploreCategorySnapshot($0) }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
