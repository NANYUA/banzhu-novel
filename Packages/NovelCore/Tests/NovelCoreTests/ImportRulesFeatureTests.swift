import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 「导入目录正则」管理页的 reducer 测试：增 / 删 / 启停 / 恢复内置 / 校验。
@MainActor
final class ImportRulesFeatureTests: XCTestCase {
    /// 记录「写回」的内容。`save` 是 `@Sendable`，用 class 盒装可变状态。
    private final class SaveRecorder: @unchecked Sendable {
        var latest: [ImportChapterRule]?
    }

    private func makeStore(
        rules: [ImportChapterRule] = BuiltinImportRules.all,
        recorder: SaveRecorder? = nil
    ) -> TestStore<ImportRulesFeature.State, ImportRulesFeature.Action> {
        var state = ImportRulesFeature.State()
        state.rules = rules
        return TestStore(initialState: state) {
            ImportRulesFeature()
        } withDependencies: {
            $0.importRuleStore = ImportRuleStore(
                load: { rules },
                save: { recorder?.latest = $0 }
            )
        }
    }

    func test进入页面_读出规则表() async {
        let store = TestStore(initialState: ImportRulesFeature.State()) {
            ImportRulesFeature()
        }
        await store.send(.onAppear)
        await store.receive(.loaded(BuiltinImportRules.all)) {
            $0.rules = BuiltinImportRules.all
        }
    }

    func test停用一条规则_立即写回() async {
        let recorder = SaveRecorder()
        let store = makeStore(recorder: recorder)
        await store.send(.toggled(id: "builtin-1")) {
            $0.rules[0].isEnabled = false
        }
        XCTAssertEqual(recorder.latest?.first?.isEnabled, false)
    }

    func test删除规则_内置的也能删() async {
        let recorder = SaveRecorder()
        let store = makeStore(recorder: recorder)
        await store.send(.deleted(id: "builtin-2")) {
            $0.rules.removeAll { $0.id == "builtin-2" }
        }
        XCTAssertEqual(store.state.rules.count, 18)
        XCTAssertEqual(recorder.latest?.count, 18)
    }

    func test新增合法规则_入表并写回() async {
        let recorder = SaveRecorder()
        let store = makeStore(recorder: recorder)
        await store.send(.addTapped) { $0.isAdding = true }
        await store.send(.draftNameChanged("我的规则")) { $0.draftName = "我的规则" }
        await store.send(.draftPatternChanged("^第[0-9]+章")) { $0.draftPattern = "^第[0-9]+章" }
        await store.send(.addConfirmed) {
            $0.rules.append(
                ImportChapterRule(
                    id: "user-19",
                    name: "我的规则",
                    pattern: "^第[0-9]+章",
                    serialNumber: 19
                )
            )
            $0.isAdding = false
            $0.draftName = ""
            $0.draftPattern = ""
        }
        XCTAssertEqual(store.state.rules.count, 20)
        XCTAssertEqual(recorder.latest?.last?.id, "user-19")
    }

    /// 坏正则挡在表单里：由 `validationMessage` 的错误文案说明原因。
    func test新增坏正则_不入表并给出原因() async {
        let recorder = SaveRecorder()
        let store = makeStore(recorder: recorder)
        let expected = ImportChapterRule(id: "user-19", name: "坏", pattern: "第(章").validationMessage
        await store.send(.addTapped) { $0.isAdding = true }
        await store.send(.draftNameChanged("坏")) { $0.draftName = "坏" }
        await store.send(.draftPatternChanged("第(章")) { $0.draftPattern = "第(章" }
        await store.send(.addConfirmed) {
            $0.draftError = expected
        }
        XCTAssertEqual(store.state.rules.count, 19, "坏正则不能进表")
        XCTAssertNil(recorder.latest, "没有任何修改时不该写回")
        XCTAssertTrue(store.state.isAdding, "失败后表单要保持打开")
    }

    func test取消新增_清空草稿() async {
        let store = makeStore()
        await store.send(.addTapped) { $0.isAdding = true }
        await store.send(.draftNameChanged("半途")) { $0.draftName = "半途" }
        await store.send(.cancelAddTapped) {
            $0.isAdding = false
            $0.draftName = ""
            $0.draftPattern = ""
            $0.draftError = nil
        }
    }

    func test恢复内置_补回缺的一条() async {
        var missing = BuiltinImportRules.all
        missing.removeAll { $0.id == "builtin-5" }
        let store = makeStore(rules: missing)
        XCTAssertEqual(store.state.missingBuiltinCount, 1)
        let restored = BuiltinImportRules.restoringMissingBuiltins(into: missing)
        await store.send(.restoreBuiltinsTapped) {
            $0.rules = restored
        }
        XCTAssertEqual(store.state.missingBuiltinCount, 0)
    }

    func test一条不缺时不显示恢复入口() {
        let store = makeStore()
        XCTAssertEqual(store.state.missingBuiltinCount, 0)
    }

    func test草稿空白时不能提交() async {
        let store = makeStore()
        await store.send(.addTapped) { $0.isAdding = true }
        XCTAssertFalse(store.state.canSubmitDraft)
        await store.send(.draftNameChanged("只有名字")) { $0.draftName = "只有名字" }
        XCTAssertFalse(store.state.canSubmitDraft, "正则为空仍不能提交")
        await store.send(.draftPatternChanged("^第")) { $0.draftPattern = "^第" }
        XCTAssertTrue(store.state.canSubmitDraft)
    }
}
