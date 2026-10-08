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

    func test自动验证成功后关闭覆盖层() async {
        let request = GuardRequest(siteURL: "https://example.com/")
        let recorder = Recorder()
        let store = TestStore(initialState: GuardFeature.State()) {
            GuardFeature()
        } withDependencies: {
            $0.guardService.autoPass = { _ in true }
            $0.guardService.resolve = { id, passed in
                await recorder.record(id, passed: passed)
            }
        }

        await store.send(.requested(request)) {
            $0.request = request
            $0.phase = .autoPassing
        }
        await store.receive(.autoPassSucceeded) {
            $0.request = nil
            $0.phase = .idle
        }
        await store.finish()

        let values = await recorder.values()
        XCTAssertEqual(values.map(\.1), [true])
    }

    func test自动验证失败后进入手动并可取消() async {
        let request = GuardRequest(siteURL: "https://example.com/")
        let recorder = Recorder()
        let store = TestStore(initialState: GuardFeature.State()) {
            GuardFeature()
        } withDependencies: {
            $0.guardService.autoPass = { _ in false }
            $0.guardService.resolve = { id, passed in
                await recorder.record(id, passed: passed)
            }
        }

        await store.send(.requested(request)) {
            $0.request = request
            $0.phase = .autoPassing
        }
        await store.receive(.autoPassFailed) {
            $0.phase = .manual
            $0.message = "自动验证未通过，请手动拖动滑块。"
        }
        await store.send(.cancelled) {
            $0.request = nil
            $0.phase = .idle
            $0.message = nil
        }
        await store.finish()

        let values = await recorder.values()
        XCTAssertEqual(values.map(\.1), [false])
    }

    func test自动验证中可切手动() async {
        let request = GuardRequest(siteURL: "https://example.com/")
        let store = TestStore(
            initialState: GuardFeature.State(request: request, phase: .autoPassing)
        ) {
            GuardFeature()
        }

        await store.send(.switchToManual) {
            $0.phase = .manual
        }
        await store.finish()
    }
}
