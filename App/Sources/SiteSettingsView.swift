import ComposableArchitecture
import NovelCore
import SwiftUI

/// 站点入口管理页（手动模式）。
struct SiteSettingsView: View {
    let store: StoreOf<SiteFeature>

    @State private var newHost = ""

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                Form {
                    navigationSection(viewStore)
                    hostSection(viewStore)

                    if let notice = viewStore.notice {
                        Section {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("站点入口")
                .onAppear { viewStore.send(.task) }
                // H5：离开本页时把编辑中的导航地址落盘（返回上一页 / 切 Tab 都会走这里）。
                .onDisappear { viewStore.send(.commitNavigationURL) }
            }
        }
    }

    private func navigationSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section("导航地址") {
            TextField(
                // B0-6 收尾：占位改成中性格式提示，不再假装有个 example.com 可用。
                "https://…",
                text: Binding(
                    get: { viewStore.settings.navigationURL },
                    set: { viewStore.send(.setNavigationURL($0)) }
                )
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            // H5：逐按键只改内存（`.setNavigationURL`），落盘统一走 `.commitNavigationURL`。
            .onSubmit { viewStore.send(.commitNavigationURL) }

            Button {
                // H5：先把编辑中的地址落盘，再拉取 —— 否则这次输入不会被记住。
                viewStore.send(.commitNavigationURL)
                viewStore.send(.fetchNavigationTapped)
            } label: {
                HStack {
                    if viewStore.isFetchingNavigation {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text("拉取 host")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewStore.isFetchingNavigation)

            if !viewStore.discoveredHosts.isEmpty {
                Text("本次发现 \(viewStore.discoveredHosts.count) 个 host，已并入下方列表")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hostSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section {
            if viewStore.settings.hosts.isEmpty {
                Text("暂无 host。点上方「拉取 host」或手动添加。")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { viewStore.isHostListExpanded },
                        set: { _ in viewStore.send(.toggleHostList) }
                    )
                ) {
                    ForEach(viewStore.settings.hosts) { entry in
                        Button {
                            viewStore.send(.selectHost(entry.id))
                        } label: {
                            hostRow(
                                entry,
                                isSelected: entry.id == viewStore.settings.currentHostID
                            )
                        }
                        .buttonStyle(PressableCardButtonStyle())
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                viewStore.send(.deleteHost(entry.id))
                            }
                        }
                    }
                } label: {
                    Text("host 列表（\(viewStore.settings.hosts.count)）")
                }
            }

            HStack {
                TextField("example.com", text: $newHost)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button {
                    viewStore.send(.addHost(newHost))
                    newHost = ""
                } label: {
                    Text("添加")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("host")
        } footer: {
            Text("相同 host 只保留一条；始终使用选中的 host，不会自动切换。")
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
            }
        }
    }
}

#Preview {
    SiteSettingsView(
        store: Store(initialState: SiteFeature.State()) {
            SiteFeature()
        }
    )
}
