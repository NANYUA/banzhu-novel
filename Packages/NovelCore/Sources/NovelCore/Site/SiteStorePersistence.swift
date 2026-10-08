import Foundation
import NovelEngine

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

    func updateHostState(_ update: HostStateUpdate) {
        var settings = load()
        settings.updateHostState(
            value: update.value,
            status: HostStatus(update.status),
            coolingUntil: update.coolingUntil
        )
        save(settings)
    }

    func recordNavigationOutcome(url: String, outcome: NavigationOutcome) {
        var settings = load()
        guard let entry = settings.navigationURLs.first(where: {
            $0.value.caseInsensitiveCompare(url) == .orderedSame
        }) else {
            return
        }
        switch outcome {
        case .success:
            settings.resetNavigationFailure(id: entry.id)
        case .failure:
            settings.recordNavigationFailure(id: entry.id)
        }
        save(settings)
    }
}

private extension HostStatus {
    init(_ status: RouteHostStatus) {
        switch status {
        case .unknown: self = .unknown
        case .unguarded: self = .unguarded
        case .guarded: self = .guarded
        case .unavailable: self = .unavailable
        }
    }
}
