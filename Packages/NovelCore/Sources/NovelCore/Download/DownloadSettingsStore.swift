import Dependencies
import Foundation

/// 下载设置的持久化快照。
///
/// 只装「用户改过的下载偏好」：队列任务由 `DownloadQueueStore` 落盘，
/// 网络类型是系统实时状态 —— 两者都不该进这里。
public struct DownloadSettings: Equatable, Sendable, Codable {
    public init(allowsCellular: Bool, speed: DownloadSpeed) {
        self.allowsCellular = allowsCellular
        self.speed = speed
    }

    /// 是否允许蜂窝网络启动下载。
    public var allowsCellular: Bool

    /// 速率档位。
    public var speed: DownloadSpeed
}

/// 下载设置读写依赖。
///
/// 与其它 IO 依赖同理：reducer 不直接碰 `UserDefaults`，
/// 测试用 `withDependencies` 换成内存桩，断言的仍是完整状态迁移。
struct DownloadSettingsStore: Sendable {
    var load: @Sendable () -> DownloadSettings?
    var save: @Sendable (DownloadSettings) -> Void
}

extension DependencyValues {
    var downloadSettingsStore: DownloadSettingsStore {
        get { self[DownloadSettingsStoreKey.self] }
        set { self[DownloadSettingsStoreKey.self] = newValue }
    }

    private enum DownloadSettingsStoreKey: DependencyKey {
        static let liveValue = DownloadSettingsStore(
            load: { DownloadSettingsLive.load() },
            save: { DownloadSettingsLive.save($0) }
        )

        /// 测试默认值：不读不写，避免忘记注入桩的测试意外污染真实设置。
        static let testValue = DownloadSettingsStore(
            load: { nil },
            save: { _ in }
        )
    }
}

/// `UserDefaults` + JSON 的落盘实现。
///
/// 不是 `private`：测试要用**独立 suite** 的 `UserDefaults` 跑真实往返
/// （写法沿用 `VerticalInsetDefaultMigration.apply(to:defaults:)`）。
enum DownloadSettingsLive {
    /// `UserDefaults` key，沿用本项目「`<域>.<用途>.v<版本>`」的既有命名习惯。
    ///
    /// 带版本号是为将来的 schema 变更留迁移位：字段增删时提版本号，
    /// 旧数据自然失效（`load()` 返回 `nil` ⇒ 调用方回到默认值），不必写迁移代码。
    static let storageKey = "download.settings.v1"

    /// 没存过 / 数据损坏一律返回 `nil`。
    ///
    /// 刻意**不**在这里给默认值：默认值只有 `DownloadFeature.State` 一个真相源，
    /// 这里再给一份会让「首装默认值」出现两处定义。坏数据也走同一条降级路径
    /// （`try?` ⇒ `nil` ⇒ 回到默认），不崩、不提示。
    static func load(defaults: UserDefaults = .standard) -> DownloadSettings? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(DownloadSettings.self, from: data)
    }

    /// 编码失败静默不写：设置没记住只是回到默认，不该让 App 崩。
    static func save(_ settings: DownloadSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
