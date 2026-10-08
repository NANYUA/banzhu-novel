import Dependencies
import Foundation
import NovelEngine

/// 一个站点入口。导航网址和 host 都是同一站点的入口，不做多站适配。
public struct SiteEntry: Codable, Equatable, Identifiable, Sendable {
    public init(
        id: UUID = UUID(),
        value: String,
        source: SiteEntrySource = .user
    ) {
        self.id = id
        self.value = value
        self.source = source
    }

    public var id: UUID
    public var value: String
    public var source: SiteEntrySource

    private enum CodingKeys: String, CodingKey {
        case id
        case value
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        value = try container.decode(String.self, forKey: .value)
        source = try container.decodeIfPresent(SiteEntrySource.self, forKey: .source) ?? .user
    }
}

/// 入口来源。导航发现和用户手动添加分开管理。
public enum SiteEntrySource: String, Codable, Equatable, Sendable {
    case user
    case navigation
}

/// 站点入口设置的持久化快照。
public struct SiteSettings: Codable, Equatable, Sendable {
    public init(
        navigationURLs: [SiteEntry] = [],
        hosts: [SiteEntry] = [],
        currentNavigationID: UUID? = nil,
        currentHostID: UUID? = nil,
        autoSwitchHost: Bool = true
    ) {
        self.navigationURLs = navigationURLs
        self.hosts = hosts
        self.currentNavigationID = currentNavigationID
        self.currentHostID = currentHostID
        self.autoSwitchHost = autoSwitchHost
        normalize()
    }

    public var navigationURLs: [SiteEntry]
    public var hosts: [SiteEntry]
    public var currentNavigationID: UUID?
    public var currentHostID: UUID?
    public var autoSwitchHost: Bool

    public var currentNavigationURL: String? {
        navigationURLs.first { $0.id == currentNavigationID }?.value
    }

    public var currentHost: String? {
        hosts.first { $0.id == currentHostID }?.value
    }

    public var userHosts: [SiteEntry] {
        hosts.filter { $0.source == .user }
    }

    public var navigationHosts: [SiteEntry] {
        hosts.filter { $0.source == .navigation }
    }

    /// 首次启动时的默认值：只从已有站点配置和环境变量读取。
    public static var `default`: SiteSettings {
        let hostValues = SiteConfig.mirrors.isEmpty
            ? [SiteConfig.default.host]
            : SiteConfig.mirrors
        let hosts = hostValues.map { SiteEntry(value: $0) }
        let navigationValues = Self.environmentNavigationURLs()
        let navigationURLs = navigationValues.map { SiteEntry(value: $0) }

        return SiteSettings(
            navigationURLs: navigationURLs,
            hosts: hosts,
            currentNavigationID: navigationURLs.first?.id,
            currentHostID: hosts.first?.id,
            autoSwitchHost: true
        )
    }

    public mutating func normalize() {
        navigationURLs = Self.normalizedEntries(navigationURLs)
        hosts = Self.normalizedEntries(hosts)

        if !navigationURLs.contains(where: { $0.id == currentNavigationID }) {
            currentNavigationID = navigationURLs.first?.id
        }
        if !hosts.contains(where: { $0.id == currentHostID }) {
            currentHostID = hosts.first?.id
        }
    }

    private static func normalizedEntries(_ entries: [SiteEntry]) -> [SiteEntry] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(key).inserted else { return nil }
            return SiteEntry(id: entry.id, value: value, source: entry.source)
        }
    }

    public mutating func recordHost(
        _ rawHost: String,
        source: SiteEntrySource = .navigation
    ) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        if let existing = hosts.first(where: {
            $0.value.caseInsensitiveCompare(host) == .orderedSame
        }) {
            currentHostID = existing.id
        } else {
            let entry = SiteEntry(value: host, source: source)
            hosts.append(entry)
            currentHostID = entry.id
        }
    }

    private static func environmentNavigationURLs() -> [String] {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_NAVIGATION_URLS"] {
            if !env.isEmpty {
                return env.components(separatedBy: ",").filter { !$0.isEmpty }
            }
        }
        #endif
        return []
    }
}

/// 站点入口读写依赖。
struct SiteStore: Sendable {
    var load: @Sendable () async -> SiteSettings
    var save: @Sendable (SiteSettings) async -> Void
    var recordHost: @Sendable (String) async -> Void
}

extension DependencyValues {
    var siteStore: SiteStore {
        get { self[SiteStoreKey.self] }
        set { self[SiteStoreKey.self] = newValue }
    }

    private enum SiteStoreKey: DependencyKey {
        static let liveValue = SiteStore(
            load: { await SiteStorePersistence.shared.load() },
            save: { settings in await SiteStorePersistence.shared.save(settings) },
            recordHost: { host in await SiteStorePersistence.shared.recordHost(host) }
        )

        static let testValue = SiteStore(
            load: { .default },
            save: { _ in },
            recordHost: { _ in }
        )
    }
}

actor SiteStorePersistence {
    static let shared = SiteStorePersistence()

    private let storageKey = "site.settings.v1"
    private var cached: SiteSettings?

    func load() -> SiteSettings {
        if let cached {
            return cached
        }
        let decoded = UserDefaults.standard.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode(SiteSettings.self, from: $0)
        }
        let settings: SiteSettings = decoded ?? .default
        cached = settings
        return settings
    }

    func save(_ settings: SiteSettings) {
        var normalized = settings
        normalized.normalize()
        cached = normalized
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func recordHost(_ rawHost: String) {
        var settings = load()
        settings.recordHost(rawHost)
        save(settings)
    }
}
