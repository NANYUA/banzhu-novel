import ComposableArchitecture
import NovelCore
import SwiftUI

/// 「目录正则」管理页：设置 → 目录正则。
///
/// ## 交互口径（owner 2026-10-17，第二轮真机反馈后再改）
/// - 内置规则只是**初始数据**，同样可以删除（删除按钮是**红色**）；
/// - 新增入口在**右上角**的**弹出菜单**里（这一版 owner 要求「右上角改为弹出选项」），
///   菜单只有一项「添加正则」，点它弹 **sheet** 输入（不再在列表底部摊开表单）；
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
                restoreSection(viewStore)
            }
            .navigationTitle("目录正则")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { viewStore.send(.onAppear) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 弹出菜单（不是直接开表单）：后续要加「导入 / 导出规则」时，
                    // 这里继续加菜单项即可，不必再动右上角的结构。
                    Menu {
                        Button {
                            viewStore.send(.addTapped)
                        } label: {
                            Label("添加正则", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("添加正则")
                }
            }
            // 输入界面用 sheet：正则可能很长，摊在列表里会把下面的规则挤走。
            .sheet(
                isPresented: Binding(
                    get: { viewStore.isAdding },
                    set: { isPresented in
                        if !isPresented {
                            viewStore.send(.cancelAddTapped)
                        }
                    }
                )
            ) {
                ImportRuleEditorView(store: store)
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
