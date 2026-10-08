import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 站点入口管理：导航网址、host、当前项与自动切换开关。
public struct SiteFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(
            settings: SiteSettings = .default,
            isLoading: Bool = false,
            notice: String? = nil
        ) {
            self.settings = settings
            self.isLoading = isLoading
            self.notice = notice
        }

        public var settings: SiteSettings
        public var isLoading: Bool
        public var notice: String?
    }

    public enum Action: Equatable {
        case task
        case loaded(SiteSettings)
        case addNavigationURL(String)
        case deleteNavigationURL(UUID)
        case selectNavigationURL(UUID)
        case addHost(String)
        case deleteHost(UUID)
        case selectHost(UUID)
        case setAutoSwitch(Bool)
        case setVerificationStartTier(VerificationStartTier)
        case setHostCooldown(Int)
        case setNavigationHostLimit(Int)
        case setStandbyTTL(Int)
        case setNavigationDisabled(UUID, Bool)
        case reloadNavigation(UUID)
        case failed(String)
        case noticeDismissed
    }

    @Dependency(\.siteStore) var siteStore
    @Dependency(\.siteRouter) var siteRouter

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                let store = siteStore
                return .run { send in
                    let settings = await store.load()
                    await send(.loaded(settings))
                }

            case let .loaded(settings):
                state.settings = settings
                state.isLoading = false
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .addNavigationURL(value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.notice = "导航网址不能为空。"
                    return .none
                }
                let entry = SiteEntry(value: trimmed, source: .user)
                state.settings.navigationURLs.append(entry)
                state.settings.currentNavigationID = entry.id
                state.settings.normalize()
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .deleteNavigationURL(id):
                state.settings.navigationURLs.removeAll { $0.id == id }
                state.settings.normalize()
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .selectNavigationURL(id):
                guard state.settings.navigationURLs.contains(where: { $0.id == id }) else {
                    return .none
                }
                state.settings.currentNavigationID = id
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .addHost(value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.notice = "host 不能为空。"
                    return .none
                }
                let entry = SiteEntry(value: trimmed)
                state.settings.hosts.append(entry)
                state.settings.currentHostID = entry.id
                state.settings.normalize()
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .deleteHost(id):
                state.settings.hosts.removeAll { $0.id == id }
                state.settings.normalize()
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .selectHost(id):
                guard state.settings.hosts.contains(where: { $0.id == id }) else {
                    return .none
                }
                state.settings.currentHostID = id
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .setAutoSwitch(enabled):
                state.settings.autoSwitchHost = enabled
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .setVerificationStartTier(tier):
                state.settings.verificationStartTier = tier
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .setHostCooldown(seconds):
                state.settings.hostCooldownSeconds = max(0, seconds)
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .setNavigationHostLimit(limit):
                state.settings.navigationHostLimit = max(1, limit)
                state.settings.normalize()
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .setStandbyTTL(seconds):
                state.settings.standbyTTLSeconds = max(0, seconds)
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .setNavigationDisabled(id, disabled):
                state.settings.setNavigationDisabled(id: id, disabled: disabled)
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .reloadNavigation(id):
                state.settings.resetNavigationFailure(id: id)
                return configureAndSave(state.settings, store: siteStore, router: siteRouter)

            case let .failed(message):
                state.isLoading = false
                state.notice = message
                return .none

            case .noticeDismissed:
                state.notice = nil
                return .none
            }
        }
    }
}

/// 把持久化设置同步给引擎。
struct SiteRouter: Sendable {
    var configure: @Sendable (SiteSettings) async -> Void
}

extension DependencyValues {
    var siteRouter: SiteRouter {
        get { self[SiteRouterKey.self] }
        set { self[SiteRouterKey.self] = newValue }
    }

    private enum SiteRouterKey: DependencyKey {
        static let liveValue = SiteRouter { settings in
            await NovelEngine.shared.configureRouting(
                SiteRoutingConfiguration(
                    hosts: settings.hosts.map(\.value),
                    navigationURLs: settings.navigationURLs.map(\.value),
                    autoSwitchHost: settings.autoSwitchHost,
                    verificationStartTier: settings.verificationStartTier,
                    currentHost: settings.currentHost,
                    hostStates: settings.hosts.map { entry in
                        HostRouteState(
                            value: entry.value,
                            status: Self.mapHostStatus(entry.hostStatus),
                            coolingUntil: entry.coolingUntil,
                            lastSucceededAt: entry.lastSucceededAt,
                            isUser: entry.isUserHost,
                            isStandby: entry.isStandby
                        )
                    },
                    navigationStates: Dictionary(
                        uniqueKeysWithValues: settings.navigationURLs.map { entry in
                            (
                                entry.value,
                                Self.mapNavigationStatus(entry.resolvedNavigationStatus())
                            )
                        }
                    ),
                    hostCooldownSeconds: settings.hostCooldownSeconds,
                    standbyTTLSeconds: settings.standbyTTLSeconds,
                    guardPass: { url in
                        await GuardCoordinator.shared.requestPass(siteURL: url)
                    },
                    onHostChanged: { host in
                        Task { await SiteStorePersistence.shared.recordHost(host) }
                    },
                    onHostStateChanged: { update in
                        Task { await SiteStorePersistence.shared.updateHostState(update) }
                    },
                    onNavigationOutcome: { url, outcome in
                        Task {
                            await SiteStorePersistence.shared.recordNavigationOutcome(
                                url: url,
                                outcome: outcome
                            )
                        }
                    }
                )
            )
        }

        static let testValue = SiteRouter { _ in }

        private static func mapHostStatus(_ status: HostStatus) -> RouteHostStatus {
            switch status {
            case .unknown: .unknown
            case .unguarded: .unguarded
            case .guarded: .guarded
            case .unavailable: .unavailable
            }
        }

        private static func mapNavigationStatus(
            _ status: NavigationStatus
        ) -> RouteNavigationStatus {
            switch status {
            case .active: .active
            case .cooling: .cooling
            case .frozen: .frozen
            case .disabled: .disabled
            }
        }
    }
}

private func configureAndSave(
    _ settings: SiteSettings,
    store: SiteStore,
    router: SiteRouter
) -> Effect<SiteFeature.Action> {
    .run { _ in
        await store.save(settings)
        await router.configure(settings)
    }
}
