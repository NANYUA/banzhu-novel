import ComposableArchitecture
import Foundation

/// 「导入目录正则」的管理页状态机：增 / 删 / 启停 / 恢复内置。
///
/// ## 为什么单独一个 feature
/// 这一页有「草稿 + 校验 + 写回」三步，且规则的读写要走 `ImportRuleStore` 依赖
/// （测试里能换成内存实现）。直接写在 View 的 `@State` 里就没法验证「坏正则被拦下」这类行为。
///
/// ## 写回时机
/// 每次启停 / 删除 / 新增都**立即写回** UserDefaults，不做「保存」按钮：
/// 规则是低风险配置项，多一次确认只会让人以为没生效。
public struct ImportRulesFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public var rules: [ImportChapterRule] = []

        /// 新增表单的草稿。`isAdding == false` 时不显示。
        public var isAdding = false
        public var draftName = ""
        public var draftPattern = ""
        /// 草稿校验失败的原因（正则编译不过 / 名称空）。
        public var draftError: String?

        public init() {}

        public var enabledCount: Int {
            rules.filter(\.isEnabled).count
        }

        /// 草稿能不能提交。真正的校验在 `addConfirmed` 里做（这里只挡空输入）。
        public var canSubmitDraft: Bool {
            !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !draftPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// 用户删掉的内置条数（用于决定「恢复内置」要不要显示）。
        public var missingBuiltinCount: Int {
            let existing = Set(rules.map(\.id))
            return BuiltinImportRules.all.filter { !existing.contains($0.id) }.count
        }
    }

    public enum Action: Equatable {
        case onAppear
        case loaded([ImportChapterRule])
        case toggled(id: String)
        case deleted(id: String)
        case addTapped
        case cancelAddTapped
        case draftNameChanged(String)
        case draftPatternChanged(String)
        case addConfirmed
        case restoreBuiltinsTapped
    }

    @Dependency(\.importRuleStore) var importRuleStore

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                let store = importRuleStore
                return .run { send in
                    await send(.loaded(store.load()))
                }

            case let .loaded(rules):
                state.rules = rules
                return .none

            case let .toggled(id):
                guard let index = state.rules.firstIndex(where: { $0.id == id }) else { return .none }
                state.rules[index].isEnabled.toggle()
                persist(state.rules)
                return .none

            case let .deleted(id):
                guard state.rules.contains(where: { $0.id == id }) else { return .none }
                state.rules.removeAll { $0.id == id }
                persist(state.rules)
                return .none

            case .addTapped:
                state.isAdding = true
                state.draftError = nil
                return .none

            case .cancelAddTapped:
                resetDraft(&state)
                return .none

            case let .draftNameChanged(value):
                state.draftName = value
                state.draftError = nil
                return .none

            case let .draftPatternChanged(value):
                state.draftPattern = value
                state.draftError = nil
                return .none

            case .addConfirmed:
                return addRule(&state)

            case .restoreBuiltinsTapped:
                let merged = BuiltinImportRules.restoringMissingBuiltins(into: state.rules)
                guard merged.count != state.rules.count else { return .none }
                state.rules = merged
                persist(state.rules)
                return .none
            }
        }
    }

    // MARK: - 私有

    private func addRule(_ state: inout State) -> Effect<Action> {
        // id 用「user-<下一个序号>」而不是 UUID：确定性 id 让测试能预测、也让存下来的表可读。
        // 与内置的 `builtin-<n>` 前缀不同 ⇒ 永远不会撞。
        let nextSerial = (state.rules.map(\.serialNumber).max() ?? 0) + 1
        let draft = ImportChapterRule(
            id: "user-\(nextSerial)",
            name: state.draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            pattern: state.draftPattern.trimmingCharacters(in: .whitespacesAndNewlines),
            serialNumber: nextSerial
        )
        if let message = draft.validationMessage {
            state.draftError = message
            return .none
        }
        state.rules.append(draft)
        persist(state.rules)
        resetDraft(&state)
        return .none
    }

    private func resetDraft(_ state: inout State) {
        state.isAdding = false
        state.draftName = ""
        state.draftPattern = ""
        state.draftError = nil
    }

    private func persist(_ rules: [ImportChapterRule]) {
        importRuleStore.save(rules)
    }
}
