import Dependencies
import Foundation
import NovelEngine

/// 入口来源。重叠 host 可同时属于多个来源。
public enum SiteEntrySource: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case user
    case navigation
}

/// host 当前探测状态。
public enum HostStatus: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case unguarded
    case guarded
    case unavailable
}

/// 导航站状态。优先级：disabled > frozen > cooling > active。
public enum NavigationStatus: String, Codable, Equatable, Sendable {
    case active
    case cooling
    case frozen
    case disabled
}

/// 一个站点入口。导航网址和 host 都是同一站点的入口，不做多站适配。
public struct SiteEntry: Codable, Equatable, Identifiable, Sendable {
    public init(
        id: UUID = UUID(),
        value: String,
        source: SiteEntrySource = .user
    ) {
        self.init(id: id, value: value, sources: [source])
    }

    public init(
        id: UUID = UUID(),
        value: String,
        sources: Set<SiteEntrySource>
    ) {
        self.id = id
        self.value = value
        self.sources = sources
    }

    public var id: UUID
    public var value: String
    public var sources: Set<SiteEntrySource> = []
    public var originNavigationIDs: Set<UUID> = []
    public var hostStatus: HostStatus = .unknown
    public var coolingUntil: Date?
    public var lastProbedAt: Date?
    public var lastVerifiedAt: Date?
    public var lastSucceededAt: Date?
    public var isStandby = false

    // 导航站专用状态。host 条目不使用。
    public var navigationStatus: NavigationStatus = .active
    public var consecutiveFailures = 0
    public var navigationCoolingUntil: Date?
    public var frozenUntil: Date?
    public var isDisabled = false

    /// 兼容旧调用点：用户来源优先。
    public var source: SiteEntrySource {
        get { sources.contains(.user) ? .user : .navigation }
        set { sources = [newValue] }
    }

    public var isUserHost: Bool {
        sources.contains(.user)
    }

    public var isNavigationHost: Bool {
        sources.contains(.navigation)
    }

    public func resolvedNavigationStatus(at now: Date = Date()) -> NavigationStatus {
        if isDisabled {
            return .disabled
        }
        if let frozenUntil, frozenUntil > now {
            return .frozen
        }
        if let navigationCoolingUntil, navigationCoolingUntil > now {
            return .cooling
        }
        return .active
    }

    public func isCooling(at now: Date = Date()) -> Bool {
        if let coolingUntil, coolingUntil > now {
            return true
        }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case value
        case source
        case sources
        case originNavigationIDs
        case hostStatus
        case coolingUntil
        case lastProbedAt
        case lastVerifiedAt
        case lastSucceededAt
        case isStandby
        case navigationStatus
        case consecutiveFailures
        case navigationCoolingUntil
        case frozenUntil
        case isDisabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        value = try container.decode(String.self, forKey: .value)
        let legacySource = try container.decodeIfPresent(SiteEntrySource.self, forKey: .source)
        let decodedSources = try container.decodeIfPresent(
            Set<SiteEntrySource>.self,
            forKey: .sources
        )
        sources = decodedSources ?? [legacySource ?? .user]
        originNavigationIDs = try container.decodeIfPresent(
            Set<UUID>.self,
            forKey: .originNavigationIDs
        ) ?? []
        hostStatus = try container.decodeIfPresent(HostStatus.self, forKey: .hostStatus) ?? .unknown
        coolingUntil = try container.decodeIfPresent(Date.self, forKey: .coolingUntil)
        lastProbedAt = try container.decodeIfPresent(Date.self, forKey: .lastProbedAt)
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        lastSucceededAt = try container.decodeIfPresent(Date.self, forKey: .lastSucceededAt)
        isStandby = try container.decodeIfPresent(Bool.self, forKey: .isStandby) ?? false
        navigationStatus = try container.decodeIfPresent(
            NavigationStatus.self,
            forKey: .navigationStatus
        ) ?? .active
        consecutiveFailures = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveFailures
        ) ?? 0
        navigationCoolingUntil = try container.decodeIfPresent(
            Date.self,
            forKey: .navigationCoolingUntil
        )
        frozenUntil = try container.decodeIfPresent(Date.self, forKey: .frozenUntil)
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(value, forKey: .value)
        try container.encode(sources, forKey: .sources)
        try container.encode(originNavigationIDs, forKey: .originNavigationIDs)
        try container.encode(hostStatus, forKey: .hostStatus)
        try container.encodeIfPresent(coolingUntil, forKey: .coolingUntil)
        try container.encodeIfPresent(lastProbedAt, forKey: .lastProbedAt)
        try container.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
        try container.encodeIfPresent(lastSucceededAt, forKey: .lastSucceededAt)
        try container.encode(isStandby, forKey: .isStandby)
        try container.encode(navigationStatus, forKey: .navigationStatus)
        try container.encode(consecutiveFailures, forKey: .consecutiveFailures)
        try container.encodeIfPresent(navigationCoolingUntil, forKey: .navigationCoolingUntil)
        try container.encodeIfPresent(frozenUntil, forKey: .frozenUntil)
        try container.encode(isDisabled, forKey: .isDisabled)
    }
}

/// 站点入口设置的持久化快照。
public struct SiteSettings: Codable, Equatable, Sendable {
    public init(
        navigationURLs: [SiteEntry] = [],
        hosts: [SiteEntry] = [],
        currentNavigationID: UUID? = nil,
        currentHostID: UUID? = nil,
        autoSwitchHost: Bool = true,
        verificationStartTier: VerificationStartTier = .second,
        hostCooldownSeconds: Int = 300,
        navigationHostLimit: Int = 9,
        standbyTTLSeconds: Int = 900
    ) {
        self.navigationURLs = navigationURLs
        self.hosts = hosts
        self.currentNavigationID = currentNavigationID
        self.currentHostID = currentHostID
        self.autoSwitchHost = autoSwitchHost
        self.verificationStartTier = verificationStartTier
        self.hostCooldownSeconds = hostCooldownSeconds
        self.navigationHostLimit = navigationHostLimit
        self.standbyTTLSeconds = standbyTTLSeconds
        normalize()
    }

    public var navigationURLs: [SiteEntry]
    public var hosts: [SiteEntry]
    public var currentNavigationID: UUID?
    public var currentHostID: UUID?
    public var autoSwitchHost: Bool
    public var verificationStartTier: VerificationStartTier
    public var hostCooldownSeconds: Int
    public var navigationHostLimit: Int
    public var standbyTTLSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case navigationURLs
        case hosts
        case currentNavigationID
        case currentHostID
        case autoSwitchHost
        case verificationStartTier
        case hostCooldownSeconds
        case navigationHostLimit
        case standbyTTLSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        navigationURLs = try container.decodeIfPresent([SiteEntry].self, forKey: .navigationURLs) ?? []
        hosts = try container.decodeIfPresent([SiteEntry].self, forKey: .hosts) ?? []
        currentNavigationID = try container.decodeIfPresent(UUID.self, forKey: .currentNavigationID)
        currentHostID = try container.decodeIfPresent(UUID.self, forKey: .currentHostID)
        autoSwitchHost = try container.decodeIfPresent(Bool.self, forKey: .autoSwitchHost) ?? true
        verificationStartTier = try container.decodeIfPresent(
            VerificationStartTier.self,
            forKey: .verificationStartTier
        ) ?? .second
        hostCooldownSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .hostCooldownSeconds
        ) ?? 300
        navigationHostLimit = try container.decodeIfPresent(
            Int.self,
            forKey: .navigationHostLimit
        ) ?? 9
        standbyTTLSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .standbyTTLSeconds
        ) ?? 900
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(navigationURLs, forKey: .navigationURLs)
        try container.encode(hosts, forKey: .hosts)
        try container.encodeIfPresent(currentNavigationID, forKey: .currentNavigationID)
        try container.encodeIfPresent(currentHostID, forKey: .currentHostID)
        try container.encode(autoSwitchHost, forKey: .autoSwitchHost)
        try container.encode(verificationStartTier, forKey: .verificationStartTier)
        try container.encode(hostCooldownSeconds, forKey: .hostCooldownSeconds)
        try container.encode(navigationHostLimit, forKey: .navigationHostLimit)
        try container.encode(standbyTTLSeconds, forKey: .standbyTTLSeconds)
    }

    public var currentNavigationURL: String? {
        navigationURLs.first { $0.id == currentNavigationID }?.value
    }

    public var currentHost: String? {
        hosts.first { $0.id == currentHostID }?.value
    }

    /// 用户来源优先；重叠 host 同时出现在两组里供 UI 标记。
    public var userHosts: [SiteEntry] {
        hosts.filter(\.isUserHost)
    }

    public var navigationHosts: [SiteEntry] {
        hosts.filter(\.isNavigationHost)
    }

    /// 首次启动时的默认值：只从已有站点配置和环境变量读取。
    public static var `default`: SiteSettings {
        let hostValues = SiteConfig.mirrors.isEmpty
            ? [SiteConfig.default.host]
            : SiteConfig.mirrors
        let hosts = hostValues.map { SiteEntry(value: $0, source: .user) }
        let navigationValues = Self.environmentNavigationURLs()
        let navigationURLs = navigationValues.map { SiteEntry(value: $0, source: .user) }

        return SiteSettings(
            navigationURLs: navigationURLs,
            hosts: hosts,
            currentNavigationID: navigationURLs.first?.id,
            currentHostID: hosts.first?.id
        )
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
