import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 站点入口管理页。
struct SiteSettingsView: View {
    let store: StoreOf<SiteFeature>

    @State private var newNavigationURL = ""
    @State private var newHost = ""
    @State private var isCustomCooldown = false

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
                            selection: SiteCooldownOption.selection(
                                viewStore,
                                isCustom: $isCustomCooldown
                            )
                        ) {
                            Text("关闭").tag(0)
                            Text("1 分钟").tag(60)
                            Text("5 分钟").tag(300)
                            Text("10 分钟").tag(600)
                            Text("30 分钟").tag(1800)
                            Text("自定义").tag(SiteCooldownOption.customTag)
                        }

                        if SiteCooldownOption.showsCustom(
                            viewStore,
                            isCustom: isCustomCooldown
                        ) {
                            Stepper(
                                "自定义冷却：\(SiteCooldownOption.minutes(viewStore)) 分钟",
                                value: Binding(
                                    get: { SiteCooldownOption.minutes(viewStore) },
                                    set: { viewStore.send(.setHostCooldown($0 * 60)) }
                                ),
                                in: 1 ... 180
                            )
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
                    navigationEntryRow(
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
                }

                Toggle(
                    "关闭导航",
                    isOn: Binding(
                        get: { entry.isDisabled },
                        set: { viewStore.send(.setNavigationDisabled(entry.id, $0)) }
                    )
                )
                .font(.subheadline)
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

    private func navigationEntryRow(_ entry: SiteEntry, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            entryRow(entry, isSelected: isSelected)
            Text(SiteNavigationStatusText.detail(entry))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// host 冷却时间的预设与「自定义」换算。
private enum SiteCooldownOption {
    /// 冷却时间预设（秒）。不在预设里的值走「自定义」。
    static let presets: Set<Int> = [0, 60, 300, 600, 1800]
    static let customTag = -1

    /// 冷却时间选择：预设值直接命中，其余值落到「自定义」。
    static func selection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>,
        isCustom: Binding<Bool>
    ) -> Binding<Int> {
        Binding(
            get: {
                let seconds = viewStore.settings.hostCooldownSeconds
                if isCustom.wrappedValue || !presets.contains(seconds) {
                    return customTag
                }
                return seconds
            },
            set: { newValue in
                if newValue == customTag {
                    isCustom.wrappedValue = true
                    if viewStore.settings.hostCooldownSeconds <= 0 {
                        viewStore.send(.setHostCooldown(60))
                    }
                } else {
                    isCustom.wrappedValue = false
                    viewStore.send(.setHostCooldown(newValue))
                }
            }
        )
    }

    static func showsCustom(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>,
        isCustom: Bool
    ) -> Bool {
        isCustom || !presets.contains(viewStore.settings.hostCooldownSeconds)
    }

    static func minutes(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> Int {
        max(1, viewStore.settings.hostCooldownSeconds / 60)
    }
}

/// 导航站状态文案：状态 + 失败次数 + 暂缓 / 冻结剩余时间。
private enum SiteNavigationStatusText {
    static func status(_ entry: SiteEntry) -> String {
        switch entry.resolvedNavigationStatus() {
        case .active: "正常"
        case .cooling: "暂缓"
        case .frozen: "冻结"
        case .disabled: "关闭"
        }
    }

    static func detail(_ entry: SiteEntry) -> String {
        var parts = ["\(status(entry)) · 失败 \(entry.consecutiveFailures) 次"]
        if let remaining = remaining(entry) {
            parts.append(remaining)
        }
        return parts.joined(separator: " · ")
    }

    /// 暂缓 / 冻结的剩余时间，供用户在设置页直接看到还要等多久。
    static func remaining(_ entry: SiteEntry) -> String? {
        let now = Date()
        let deadline: Date? = switch entry.resolvedNavigationStatus(at: now) {
        case .frozen: entry.frozenUntil
        case .cooling: entry.navigationCoolingUntil
        case .active, .disabled: nil
        }
        guard let deadline, deadline > now else { return nil }
        let seconds = Int(deadline.timeIntervalSince(now).rounded(.up))
        return seconds >= 60 ? "剩余 \(seconds / 60) 分" : "剩余 \(seconds) 秒"
    }
}

#Preview {
    SiteSettingsView(
        store: Store(initialState: SiteFeature.State()) {
            SiteFeature()
        }
    )
}
