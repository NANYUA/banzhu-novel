import Foundation

actor SiteStorePersistence {
    static let shared = SiteStorePersistence()

    private let storageKey = "site.settings.v2"
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
}
