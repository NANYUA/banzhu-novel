import ComposableArchitecture
import NovelCore
import SwiftUI

/// 「添加正则」输入界面（sheet）。
///
/// owner 2026-10-17 第二轮真机反馈：新增入口改成「右上角弹出菜单 → 添加正则 → 弹出输入界面」，
/// 不再把表单摊在规则列表底部（正则会很长，摊着会把下面的规则挤走）。
///
/// 状态仍归 `ImportRulesFeature` 所有（`isAdding` / `draftName` / `draftPattern` / `draftError`），
/// 本视图只负责呈现与转发：**关闭 sheet = `.cancelAddTapped`**，添加成功后由 reducer 把 `isAdding` 置回
/// `false`，sheet 随之收起。
struct ImportRuleEditorView: View {
    let store: StoreOf<ImportRulesFeature>

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                Form {
                    Section {
                        TextField(
                            "名称（例如：我的规则）",
                            text: viewStore.binding(
                                get: \.draftName,
                                send: ImportRulesFeature.Action.draftNameChanged
                            )
                        )
                        TextField(
                            "正则",
                            text: viewStore.binding(
                                get: \.draftPattern,
                                send: ImportRulesFeature.Action.draftPatternChanged
                            )
                        )
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        if let error = viewStore.draftError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } footer: {
                        Text("正则会按「整行」匹配：命中即把这一行当章标题。")
                    }
                }
                .navigationTitle("添加正则")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            viewStore.send(.cancelAddTapped)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            viewStore.send(.addConfirmed)
                        }
                        .disabled(!viewStore.canSubmitDraft)
                    }
                }
            }
            // 从 sheet 上缘下滑关闭时也要把草稿清掉，否则下次打开会看到上次残留的正则。
            .onDisappear {
                if viewStore.isAdding {
                    viewStore.send(.cancelAddTapped)
                }
            }
        }
    }
}
