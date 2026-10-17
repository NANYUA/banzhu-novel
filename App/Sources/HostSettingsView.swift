import ComposableArchitecture
import NovelCore
import SwiftUI

/// 设置 → 域名（二级页）：选域名、删域名、**添加域名**。
///
/// ## 为什么把「添加域名」搬到这里（owner 2026-10-17 真机口径）
/// 设置首页要保持「域名 / 手动过验证 / 目录正则」三张卡片形状一致 —— 每张卡只有一行。
/// 首页那张卡里再塞 TextField + 添加按钮，既撑高了卡片，也和另外两张不成一套。
/// ⇒ 首页只留「域名 + 当前值 + 箭头」，列表与添加都进这一页。
struct HostSettingsView: View {
    let store: StoreOf<SiteFeature>

    @State private var newHost = ""

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            Form {
                listSection(viewStore)
                addSection(viewStore)
            }
            .navigationTitle("域名")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func listSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section {
            if viewStore.settings.hosts.isEmpty {
                Text("暂无域名")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewStore.settings.hosts) { entry in
                    let isSelected = entry.id == viewStore.settings.currentHostID
                    Button {
                        viewStore.send(.selectHost(entry.id))
                    } label: {
                        hostRow(entry, isSelected: isSelected)
                    }
                    .buttonStyle(PressableCardButtonStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            viewStore.send(.deleteHost(entry.id))
                        }
                        .tint(.red)
                    }
                }
            }
        } header: {
            Text("已保存的域名")
        } footer: {
            Text("相同域名只保留一条；始终使用选中的域名，不会自动切换。")
        }
    }

    private func addSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section {
            HStack(spacing: DesignTokens.Spacing.sm) {
                TextField("请输入域名", text: $newHost)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button {
                    viewStore.send(.addHost(newHost))
                    newHost = ""
                } label: {
                    Text("添加")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("添加域名")
        } footer: {
            Text("只填域名（例如 abc123.com），不要带 https:// 与路径。")
        }
    }

    private func hostRow(_ entry: SiteEntry, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(entry.value)
                    .lineLimit(1)
                if entry.isFromNavigation {
                    Text("导航发现")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    // 装饰性图形：选中语义交给行 Button 的 `.isSelected` trait。
                    .accessibilityHidden(true)
            }
        }
    }
}

#Preview {
    NavigationStack {
        HostSettingsView(
            store: Store(initialState: SiteFeature.State()) {
                SiteFeature()
            }
        )
    }
}
