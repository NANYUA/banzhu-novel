import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 站点入口管理页。
struct SiteSettingsView: View {
    let store: StoreOf<SiteFeature>

    @State private var newNavigationURL = ""
    @State private var newHost = ""

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                Form {
                    Section {
                        Toggle(
                            "自动更换 host",
                            isOn: Binding(
                                get: { viewStore.settings.autoSwitchHost },
                                set: { viewStore.send(.setAutoSwitch($0)) }
                            )
                        )
                        Picker(
                            "何时验证",
                            selection: Binding(
                                get: { viewStore.settings.verificationStartTier },
                                set: { viewStore.send(.setVerificationStartTier($0)) }
                            )
                        ) {
                            Text("先换 host").tag(VerificationStartTier.second)
                            Text("立即验证").tag(VerificationStartTier.first)
                        }
                        .pickerStyle(.segmented)

                        Picker(
                            "host 冷却",
                            selection: Binding(
                                get: { viewStore.settings.hostCooldownSeconds },
                                set: { viewStore.send(.setHostCooldown($0)) }
                            )
                        ) {
                            Text("关闭").tag(0)
                            Text("1 分钟").tag(60)
                            Text("5 分钟").tag(300)
                            Text("10 分钟").tag(600)
                            Text("30 分钟").tag(1800)
                        }

                        Picker(
                            "导航 host 上限",
                            selection: Binding(
                                get: { viewStore.settings.navigationHostLimit },
                                set: { viewStore.send(.setNavigationHostLimit($0)) }
                            )
                        ) {
                            Text("3").tag(3)
                            Text("6").tag(6)
                            Text("9").tag(9)
                            Text("12").tag(12)
                        }

                        Picker(
                            "备用 host 缓存",
                            selection: Binding(
                                get: { viewStore.settings.standbyTTLSeconds },
                                set: { viewStore.send(.setStandbyTTL($0)) }
                            )
                        ) {
                            Text("5 分钟").tag(300)
                            Text("15 分钟").tag(900)
                            Text("30 分钟").tag(1800)
                        }
                    } footer: {
                        Text("先换 host：优先尝试不需要验证的地址。立即验证：当前地址被盾时马上验证。")
                    }

                    navigationSection(viewStore)
                    hostSections(viewStore)

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
            }
        }
    }

    private func navigationSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section("导航网址") {
            ForEach(viewStore.settings.navigationURLs) { entry in
                Button {
                    viewStore.send(.selectNavigationURL(entry.id))
                } label: {
                    entryRow(
                        entry,
                        isSelected: entry.id == viewStore.settings.currentNavigationID
                    )
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("删除", role: .destructive) {
                        viewStore.send(.deleteNavigationURL(entry.id))
                    }
                }
                .contextMenu {
                    Button("重新拉取") {
                        viewStore.send(.reloadNavigation(entry.id))
                    }
                    Button(entry.isDisabled ? "启用导航" : "关闭导航") {
                        viewStore.send(.setNavigationDisabled(entry.id, !entry.isDisabled))
                    }
                }
            }

            HStack {
                TextField("https://导航网址", text: $newNavigationURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("添加") {
                    viewStore.send(.addNavigationURL(newNavigationURL))
                    newNavigationURL = ""
                }
                .disabled(newNavigationURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func hostSections(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        userHostSection(viewStore)
        navigationHostSection(viewStore)
    }

    private func userHostSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section("用户添加的 host") {
            ForEach(viewStore.settings.userHosts) { entry in
                Button {
                    viewStore.send(.selectHost(entry.id))
                } label: {
                    entryRow(
                        entry,
                        isSelected: entry.id == viewStore.settings.currentHostID
                    )
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("删除", role: .destructive) {
                        viewStore.send(.deleteHost(entry.id))
                    }
                }
            }

            HStack {
                TextField("example.com", text: $newHost)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("添加") {
                    viewStore.send(.addHost(newHost))
                    newHost = ""
                }
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func navigationHostSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section {
            if viewStore.settings.navigationHosts.isEmpty {
                Text("暂无导航发现的 host")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewStore.settings.navigationHosts) { entry in
                    Button {
                        viewStore.send(.selectHost(entry.id))
                    } label: {
                        entryRow(
                            entry,
                            isSelected: entry.id == viewStore.settings.currentHostID
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            viewStore.send(.deleteHost(entry.id))
                        }
                    }
                }
            }
        } header: {
            Text("导航发现的 host")
        } footer: {
            Text("导航页解析成功后会加入这里，和手动添加的 host 分开保存。")
        }
    }

    private func entryRow(_ entry: SiteEntry, isSelected: Bool) -> some View {
        HStack {
            Text(entry.value)
                .lineLimit(1)
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
