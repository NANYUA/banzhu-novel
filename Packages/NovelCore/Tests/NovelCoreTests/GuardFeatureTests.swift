import ComposableArchitecture
@testable import NovelCore
import XCTest

@MainActor
final class GuardFeatureTests: XCTestCase {
    private actor Recorder {
        var resolved: [(UUID, Bool)] = []

        func record(_ id: UUID, passed: Bool) {
            resolved.append((id, passed))
        }

        func values() -> [(UUID, Bool)] {
            resolved
        }
    }

    func test请求到达时直接弹出手动验证() async {
        let request = GuardRequest(siteURL: "https://example.com/")
        let store = TestStore(initialState: GuardFeature.State()) {
            GuardFeature()
        }

        await store.send(.requested(request)) {
            $0.request = request
        }
        await store.finish()
    }

    func test手动完成后resolve为true并关闭弹窗() async {
        let request = GuardRequest(siteURL: "https://example.com/")
        let recorder = Recorder()
        let store = TestStore(initialState: GuardFeature.State(request: request)) {
            GuardFeature()
        } withDependencies: {
            $0.guardService.resolve = { id, passed in
                await recorder.record(id, passed: passed)
            }
        }

        await store.send(.manualCompleted) {
            $0.request = nil
        }
        await store.finish()

        let values = await recorder.values()
        XCTAssertEqual(values.map(\.1), [true])
    }

    func test取消后resolve为false并关闭弹窗() async {
        let request = GuardRequest(siteURL: "https://example.com/")
        let recorder = Recorder()
        let store = TestStore(initialState: GuardFeature.State(request: request)) {
            GuardFeature()
        } withDependencies: {
            $0.guardService.resolve = { id, passed in
                await recorder.record(id, passed: passed)
            }
        }

        await store.send(.cancelled) {
            $0.request = nil
        }
        await store.finish()

        let values = await recorder.values()
        XCTAssertEqual(values.map(\.1), [false])
    }
}
