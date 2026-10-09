import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 站点入口管理（手动模式）：
/// - 只能点「拉取」按钮从导航地址拉 host，不自动拉取。
/// - 拉到的与手填的 host 在同一列表，按规范化 key 去重互斥。
/// - 始终使用用户选中的 host，不自动切换。
public struct SiteFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(
            settings: SiteSettings = .default,
            isLoading: Bool = false,
            isFetchingNavigation: Bool = false,
            discoveredHosts: [SiteEntry] = [],
            isHostListExpanded: Bool = true,
            notice: String? = nil
        ) {
            self.settings = settings
            self.isLoading = isLoading
            self.isFetchingNavigation = isFetchingNavigation
            self.discoveredHosts = discoveredHosts
            self.isHostListExpanded = isHostListExpanded
            self.notice = notice
        }

        public var settings: SiteSettings
        public var isLoading = false
        public var isFetchingNavigation = false
        /// 最近一次按钮拉取的结果（用于「本次发现」高亮与空结果提示）。
        public var discoveredHosts: [SiteEntry]
        public var isHostListExpanded = true
        public var notice: String?
    }

    public enum Action: Equatable {
        case task
        case loaded(SiteSettings)
        case setNavigationURL(String)
        case fetchNavigationTapped
        case navigationSucceeded([SiteEntry])
        case navigationFailed(String)
        case toggleHostList
        case addHost(String)
        case deleteHost(UUID)
        case selectHost(UUID)
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
                return configure(state.settings, router: siteRouter)

            case let .setNavigationURL(value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.notice = "导航地址不能为空。"
                    return .none
                }
                state.settings.navigationURL = trimmed
                return saveAndConfigure(state.settings, store: siteStore, router: siteRouter)

            case .fetchNavigationTapped:
                guard !state.isFetchingNavigation else { return .none }
                // B0-6 Step 2：没配置导航地址时直接给出明确提示，不发请求——
                // 否则会拿空地址去打网络、最终报「服务器响应异常」，把「没配置」伪装成故障。
                let normalized = state.settings.navigationURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    state.notice = "请先填写导航地址。"
                    return .none
                }
                state.settings.navigationURL = normalized
                state.isFetchingNavigation = true
                state.notice = nil
                let navURL = normalized
                return .run { send in
                    do {
                        let hosts = try await NovelEngine.shared.resolveCandidates(fromNav: navURL)
                        await send(.navigationSucceeded(
                            hosts.map { SiteEntry(value: $0, isFromNavigation: true) }
                        ))
                    } catch {
                        await send(.navigationFailed(error.localizedDescription))
                    }
                }

            case let .navigationSucceeded(entries):
                state.isFetchingNavigation = false
                for entry in entries {
                    state.settings.upsertHost(entry.value, isFromNavigation: true)
                }
                state.discoveredHosts = entries
                state.isHostListExpanded = true
                return saveAndConfigure(state.settings, store: siteStore, router: siteRouter)

            case let .navigationFailed(message):
                state.isFetchingNavigation = false
                state.notice = "拉取失败：\(message)"
                return .none

            case .toggleHostList:
                state.isHostListExpanded.toggle()
                return .none

            case let .addHost(value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.notice = "host 不能为空。"
                    return .none
                }
                state.settings.upsertHost(trimmed, isFromNavigation: false)
                return saveAndConfigure(state.settings, store: siteStore, router: siteRouter)

            case let .deleteHost(id):
                state.settings.hosts.removeAll { $0.id == id }
                state.settings.normalize()
                return saveAndConfigure(state.settings, store: siteStore, router: siteRouter)

            case let .selectHost(id):
                guard state.settings.hosts.contains(where: { $0.id == id }) else {
                    return .none
                }
                state.settings.currentHostID = id
                return saveAndConfigure(state.settings, store: siteStore, router: siteRouter)

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

/// 把持久化设置同步给引擎（手动模式：只有当前 host + 弹窗回调）。
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
                    host: settings.currentHostValue ?? "",
                    guardPass: { url in
                        await GuardCoordinator.shared.requestPass(siteURL: url)
                    }
                )
            )
        }

        static let testValue = SiteRouter { _ in }
    }
}

private func configure(
    _ settings: SiteSettings,
    router: SiteRouter
) -> Effect<SiteFeature.Action> {
    .run { _ in
        await router.configure(settings)
    }
}

private func saveAndConfigure(
    _ settings: SiteSettings,
    store: SiteStore,
    router: SiteRouter
) -> Effect<SiteFeature.Action> {
    .run { _ in
        await store.save(settings)
        await router.configure(settings)
    }
}
