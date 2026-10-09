import Dependencies
import Foundation
import NovelEngine

/// 站点入口。手动模式下不区分来源：导航拉到的与手填的都在同一列表，按 key 去重互斥。
public struct SiteEntry: Codable, Equatable, Identifiable, Sendable {
    public init(id: UUID = UUID(), value: String, isFromNavigation: Bool = false) {
        self.id = id
        self.value = value
        self.isFromNavigation = isFromNavigation
    }

    public var id: UUID
    public var value: String
    /// UI 标记用（「导航发现」角标），不参与行为差异。
    public var isFromNavigation = false

    public var normalizedKey: String {
        SiteSettings.canonicalHostKey(value)
    }
}

/// 站点入口设置的持久化快照（手动模式）。
public struct SiteSettings: Codable, Equatable, Sendable {
    public init(
        navigationURL: String = "https://192.2.245.225",
        hosts: [SiteEntry] = [],
        currentHostID: UUID? = nil
    ) {
        self.navigationURL = navigationURL
        self.hosts = hosts
        self.currentHostID = currentHostID
        normalize()
    }

    public var navigationURL: String
    public var hosts: [SiteEntry]
    public var currentHostID: UUID?

    private enum CodingKeys: String, CodingKey {
        case navigationURL
        case hosts
        case currentHostID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        navigationURL = try container.decodeIfPresent(String.self, forKey: .navigationURL)
            ?? "https://192.2.245.225"
        hosts = try container.decodeIfPresent([SiteEntry].self, forKey: .hosts) ?? []
        currentHostID = try container.decodeIfPresent(UUID.self, forKey: .currentHostID)
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(navigationURL, forKey: .navigationURL)
        try container.encode(hosts, forKey: .hosts)
        try container.encodeIfPresent(currentHostID, forKey: .currentHostID)
    }

    public var currentHost: SiteEntry? {
        hosts.first { $0.id == currentHostID }
    }

    public var currentHostValue: String? {
        currentHost?.value
    }

    public static var `default`: SiteSettings {
        SiteSettings()
    }

    /// 去重互斥：同一 host 只保留一条；无选中时回落到第一条。
    public mutating func normalize() {
        var seen = Set<String>()
        hosts = hosts.filter { seen.insert($0.normalizedKey).inserted }
        if currentHostID == nil || !hosts.contains(where: { $0.id == currentHostID }) {
            currentHostID = hosts.first?.id
        }
    }

    public mutating func upsertHost(_ entry: SiteEntry) {
        let key = SiteSettings.canonicalHostKey(entry.value)
        guard !key.isEmpty else { return }
        if let index = hosts.firstIndex(where: { $0.normalizedKey == key }) {
            if entry.isFromNavigation {
                hosts[index].isFromNavigation = true
            }
        } else {
            hosts.append(entry)
        }
        normalize()
    }

    public static func canonicalHostKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty else { return "" }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased()
        else {
            return value.lowercased()
        }
        let scheme = (components.scheme ?? "https").lowercased()
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = components.port, port != defaultPort else {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }
}

/// 站点入口读写依赖。
struct SiteStore: Sendable {
    var load: @Sendable () async -> SiteSettings
    var save: @Sendable (SiteSettings) async -> Void
}

extension DependencyValues {
    var siteStore: SiteStore {
        get { self[SiteStoreKey.self] }
        set { self[SiteStoreKey.self] = newValue }
    }

    private enum SiteStoreKey: DependencyKey {
        static let liveValue = SiteStore(
            load: { await SiteStorePersistence.shared.load() },
            save: { await SiteStorePersistence.shared.save($0) }
        )

        static let testValue = SiteStore(
            load: { .default },
            save: { _ in }
        )
    }
}
