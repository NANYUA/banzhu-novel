import ComposableArchitecture
import NovelCore
import SwiftUI

/// 「目录正则」管理页：设置 → 目录正则。
///
/// ## 交互口径（owner 2026-10-17）
/// - 内置规则只是**初始数据**，同样可以删除（删除按钮是**红色**）；
/// - 新增入口在**右上角**，图标与书架分组栏的「新建分组」一致（`plus.circle.fill`），
///   点它把表单收进列表上方；正则当场校验，编译不过不让加；
/// - 删掉的内置规则可用「恢复内置」补回，且**不会**覆盖用户自己新建的。
///
/// 所有修改立即生效并写回（没有「保存」按钮），导入时读的就是这张表。
struct ImportRulesView: View {
    @State private var store = Store(initialState: ImportRulesFeature.State()) {
        ImportRulesFeature()
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            Form {
                rulesSection(viewStore)
                if viewStore.isAdding {
                    draftSection(viewStore)
                }
                restoreSection(viewStore)
            }
            .navigationTitle("目录正则")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { viewStore.send(.onAppear) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewStore.send(.addTapped)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    // 表单已经摊开时再点没有意义，置灰比「点了没反应」清楚。
                    .disabled(viewStore.isAdding)
                    .accessibilityLabel("新建规则")
                }
            }
        }
    }

    // MARK: - 规则列表

    private func rulesSection(
        _ viewStore: ViewStore<ImportRulesFeature.State, ImportRulesFeature.Action>
    ) -> some View {
        Section {
            ForEach(viewStore.rules) { rule in
                ruleRow(rule, viewStore)
            }
        } header: {
            Text("启用中的规则（\(viewStore.enabledCount)/\(viewStore.rules.count)）")
        } footer: {
            Text("导入时逐行尝试这些正则，命中即视为章标题。左滑可删除（内置的也能删）。")
        }
    }

    private func ruleRow(
        _ rule: ImportChapterRule,
        _ viewStore: ViewStore<ImportRulesFeature.State, ImportRulesFeature.Action>
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in viewStore.send(.toggled(id: rule.id)) }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                Text(rule.pattern)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                viewStore.send(.deleted(id: rule.id))
            } label: {
                Label("删除", systemImage: "trash")
            }
            // 显式红色：`role: .destructive` 在本页的 Form / Toggle 组合下会被系统染成蓝色
            // （owner 2026-10-17 真机反馈「左滑删除是蓝色」）。
            .tint(.red)
        }
    }

    // MARK: - 新建（由右上角 + 触发）

    private func draftSection(
        _ viewStore: ViewStore<ImportRulesFeature.State, ImportRulesFeature.Action>
    ) -> some View {
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
            HStack {
                Button("取消") { viewStore.send(.cancelAddTapped) }
                    .buttonStyle(.borderless)
                Spacer()
                Button("添加") { viewStore.send(.addConfirmed) }
                    .buttonStyle(.borderless)
                    .disabled(!viewStore.canSubmitDraft)
            }
        } header: {
            Text("新建规则")
        } footer: {
            Text("正则会按「整行」匹配：命中即把这一行当章标题。")
        }
    }

    // MARK: - 恢复内置

    @ViewBuilder
    private func restoreSection(
        _ viewStore: ViewStore<ImportRulesFeature.State, ImportRulesFeature.Action>
    ) -> some View {
        if viewStore.missingBuiltinCount > 0 {
            Section {
                Button {
                    viewStore.send(.restoreBuiltinsTapped)
                } label: {
                    Label(
                        "恢复内置规则（缺 \(viewStore.missingBuiltinCount) 条）",
                        systemImage: "arrow.counterclockwise"
                    )
                }
            } footer: {
                Text("只补回被删掉的内置规则，不会覆盖你自己新建的规则。")
            }
        }
    }
}
