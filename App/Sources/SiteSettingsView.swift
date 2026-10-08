import ComposableArchitecture
import NovelCore
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
                    } footer: {
                        Text("当前 host 不可用时，按已保存 host 顺序切换；全部失败后再用导航网址解析新 host。")
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
