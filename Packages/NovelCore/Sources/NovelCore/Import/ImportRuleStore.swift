import Dependencies
import Foundation

/// 「导入目录正则」的持久化（UserDefaults 存 JSON）。
///
/// ## 为什么用 UserDefaults 而不是 SwiftData
/// 规则是**几百字节级**的纯配置，与书架/正文没有关系键；为它加一张表就要动
/// `NovelStore.schema`（漏登记会编译报错，改 schema 还涉及迁移），代价明显大于收益。
/// `SiteStorePersistence` / `DownloadSettingsStore` 也是同一条路子。
///
/// ## 存储格式与版本
/// key 里带 `.v1`：以后改结构就换 key，**不做迁移**（规则可以一键「恢复内置」重建）。
struct ImportRuleStore: Sendable {
    var load: @Sendable () -> [ImportChapterRule]
    var save: @Sendable ([ImportChapterRule]) -> Void
}

extension DependencyValues {
    /// 导入规则表。测试里用 `withDependencies { $0.importRuleStore = … }` 换成内存实现。
    var importRuleStore: ImportRuleStore {
        get { self[ImportRuleStoreKey.self] }
        set { self[ImportRuleStoreKey.self] = newValue }
    }

    private enum ImportRuleStoreKey: DependencyKey {
        static let liveValue = ImportRuleStore(
            load: { ImportRulePersistence.load() },
            save: { ImportRulePersistence.save($0) }
        )

        /// 测试默认值用**内置表**而不是空表：空表会让「切章」相关的测试全部走兜底分支，
        /// 看起来是通过了，实际什么规则都没验证。
        static let testValue = ImportRuleStore(
            load: { BuiltinImportRules.all },
            save: { _ in }
        )
    }
}

/// 真正的读写。
enum ImportRulePersistence {
    static let key = "import.chapterRules.v1"

    static func load() -> [ImportChapterRule] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let rules = try? JSONDecoder().decode([ImportChapterRule].self, from: data)
        else {
            // 没有用户数据 = 首次启动，用内置表。
            return BuiltinImportRules.all
        }
        return rules.sorted { $0.serialNumber < $1.serialNumber }
    }

    static func save(_ rules: [ImportChapterRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
