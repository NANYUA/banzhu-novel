import ComposableArchitecture
import Dependencies
import Foundation

/// 验证弹窗状态。无任何自动流程：弹出后等待用户手动完成或取消。
public struct GuardFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(request: GuardRequest? = nil, message: String? = nil) {
            self.request = request
            self.message = message
        }

        public var request: GuardRequest?
        public var message: String?

        public var isPresented: Bool {
            request != nil
        }
    }

    public enum Action: Equatable {
        case task
        case requested(GuardRequest)
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
                state.message = nil
                return .none

            case .manualCompleted:
                guard let request = state.request else { return .none }
                state.request = nil
                state.message = nil
                let service = guardService
                return .run { _ in
                    await service.resolve(request.id, true)
                }

            case .cancelled:
                guard let request = state.request else { return .none }
                state.request = nil
                state.message = nil
                let service = guardService
                return .run { _ in
                    await service.resolve(request.id, false)
                }
            }
        }
    }
}

/// GuardFeature 依赖。测试里替换成内存事件流与记录器。
struct GuardService: Sendable {
    var events: @Sendable () async -> AsyncStream<GuardRequest>
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
            resolve: { id, passed in
                await GuardCoordinator.shared.resolve(id: id, passed: passed)
            }
        )

        static let testValue = GuardService(
            events: { AsyncStream { _ in } },
            resolve: { _, _ in }
        )
    }
}
