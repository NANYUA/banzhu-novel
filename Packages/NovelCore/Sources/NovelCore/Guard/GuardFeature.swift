import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 全局过验证状态。
///
/// 自动过盾期间界面保持可见；失败后自动切到手动验证，用户也可以随时手动切换或取消。
public struct GuardFeature: Reducer {
    public init() {}

    public enum Phase: Equatable, Sendable {
        case idle
        case autoPassing
        case manual
    }

    public struct State: Equatable {
        public init(
            request: GuardRequest? = nil,
            phase: Phase = .idle,
            message: String? = nil
        ) {
            self.request = request
            self.phase = phase
            self.message = message
        }

        public var request: GuardRequest?
        public var phase: Phase
        public var message: String?

        public var isPresented: Bool {
            request != nil
        }
    }

    public enum Action: Equatable {
        case task
        case requested(GuardRequest)
        case autoPassSucceeded
        case autoPassFailed
        case switchToManual
        case manualCompleted
        case cancelled
    }

    @Dependency(\.guardService) var guardService

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                let service = guardService
                return .run { send in
                    let events = await service.events()
                    for await request in events {
                        await send(.requested(request))
                    }
                }

            case let .requested(request):
                state.request = request
                state.phase = .autoPassing
                state.message = nil
                let service = guardService
                return .run { send in
                    let passed = await service.autoPass(request.siteURL)
                    if passed {
                        await service.resolve(request.id, true)
                        await send(.autoPassSucceeded)
                    } else {
                        await send(.autoPassFailed)
                    }
                }

            case .autoPassSucceeded:
                state.request = nil
                state.phase = .idle
                state.message = nil
                return .none

            case .autoPassFailed:
                state.phase = .manual
                state.message = "自动验证未通过，请手动拖动滑块。"
                return .none

            case .switchToManual:
                guard state.request != nil else { return .none }
                state.phase = .manual
                state.message = nil
                return .none

            case .manualCompleted:
                guard let request = state.request else { return .none }
                state.request = nil
                state.phase = .idle
                state.message = nil
                let service = guardService
                return .run { _ in
                    await service.resolve(request.id, true)
                }

            case .cancelled:
                guard let request = state.request else { return .none }
                state.request = nil
                state.phase = .idle
                state.message = nil
                let service = guardService
                return .run { _ in
                    await service.resolve(request.id, false)
                }
            }
        }
    }
}

/// GuardFeature 依赖。测试里替换成内存事件流与假验证结果。
struct GuardService: Sendable {
    var events: @Sendable () async -> AsyncStream<GuardRequest>
    var autoPass: @Sendable (String) async -> Bool
    var resolve: @Sendable (UUID, Bool) async -> Void
}

extension DependencyValues {
    var guardService: GuardService {
        get { self[GuardServiceKey.self] }
        set { self[GuardServiceKey.self] = newValue }
    }

    private enum GuardServiceKey: DependencyKey {
        static let liveValue = GuardService(
            events: { await GuardCoordinator.shared.events() },
            autoPass: { await NovelEngine.shared.autoPassGuard(urlString: $0) },
            resolve: { id, passed in
                await GuardCoordinator.shared.resolve(id: id, passed: passed)
            }
        )

        static let testValue = GuardService(
            events: { AsyncStream { _ in } },
            autoPass: { _ in false },
            resolve: { _, _ in }
        )
    }
}
