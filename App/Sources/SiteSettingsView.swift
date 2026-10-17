import ComposableArchitecture
import NovelCore
import SwiftUI

/// 站点入口管理页（手动模式）。
struct SiteSettingsView: View {
    let store: StoreOf<SiteFeature>

    /// 盾页是否正在展示（`GuardFeature.State.isPresented`）：直接复用既有状态做「正在验证」反馈，
    /// 不在本页复制一份。
    let guardIsPresented: Bool

    /// 最近一次**由本页按钮触发**的验证是否通过（`GuardCoordinator.requestPass` 的返回值）。
    let lastGuardOutcome: Bool?

    /// 「手动过验证」的触发能力：由 `RootView` 注入（全局 `guardStore` 在它那里）。
    /// 内部走的是**与网络层命中盾时完全相同**的那条入口 —— `GuardCoordinator.requestPass`
    /// （`SiteFeature.SiteRouter` 的 `guardPass` 同样调它）⇒ 本页不建第二个 store，
    /// 也就不会出现两个验证会话 / 两份 Cookie 写入。
    let onManualGuard: () -> Void

    @State private var newHost = ""

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                Form {
                    navigationSection(viewStore)
                    hostSection(viewStore)
                    manualGuardSection(viewStore)

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
            // 底栏**背景**声明为「始终可见」：iOS 15+ 的底栏有 scroll-edge 外观，
            // 内容没滚动（本页 Form 通常不够长、不可滚动）时背景本来就是透明的 ——
            // 真机「底栏毛玻璃消失」就是它。与另外三个 tab 根视图同一口径
            // （BookshelfView / ExploreView / SearchView 各有一条同样的声明）。
            .toolbarBackground(.visible, for: .tabBar)
        }
    }

    private func navigationSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section("导航地址") {
            TextField(
                // U1-3：占位改成纯中文语义提示 —— 不再用 `https://…` 这类半英文格式占位，
                // 输入格式交给 keyboardType(.URL) 提示。
                "请输入导航地址",
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
                    Text("拉取域名")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewStore.isFetchingNavigation)

            if !viewStore.discoveredHosts.isEmpty {
                Text("本次发现 \(viewStore.discoveredHosts.count) 个域名，已并入下方列表")
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
                Text("暂无域名。点上方「拉取域名」或手动添加。")
                    .foregroundStyle(.secondary)
            } else {
                hostListSection(viewStore)
            }

            HStack {
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
            Text("域名")
        } footer: {
            Text("相同域名只保留一条；始终使用选中的域名，不会自动切换。")
        }
    }

    /// 「验证」节：随时主动触发一次人机验证，不必等盾页自己弹出来。
    ///
    /// 触发能力由 `RootView` 注入（`onManualGuard`），落到 `GuardCoordinator.requestPass`
    /// —— 与网络层命中盾、盾页弹窗是**同一条路径**；本页只负责发起与展示状态。
    private func manualGuardSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        let isAvailable = !guardIsPresented && viewStore.settings.currentHostValue != nil
        return Section {
            Button {
                onManualGuard()
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if guardIsPresented {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text("手动过验证")
                    Spacer()
                }
                // 自定义 `ButtonStyle` 不会自己变灰（同 `DownloadSelectionCard` 的口径）：
                // 不可用时整行换次级色，避免「看着能点却没反应」。
                .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableCardButtonStyle(
                shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
            ))
            .disabled(!isAvailable)
            .accessibilityLabel(isAvailable ? "手动过验证" : "手动过验证，不可用")
        } header: {
            Text("验证")
        } footer: {
            if viewStore.settings.currentHostValue == nil {
                Text("请先在下方配置并选择一个域名。")
            } else if let outcome = lastGuardOutcome {
                Text(outcome ? "验证已通过。" : "验证未通过。")
            }
        }
    }

    /// 域名列表本体：默认收起，收起态只展示「当前选中的那条 host」；
    /// 展开后才显示完整列表（可切换 / 删除）。
    private func hostListSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { viewStore.isHostListExpanded },
                set: { _ in viewStore.send(.toggleHostList) }
            )
        ) {
            ForEach(viewStore.settings.hosts) { entry in
                let isSelected = entry.id == viewStore.settings.currentHostID
                Button {
                    viewStore.send(.selectHost(entry.id))
                } label: {
                    hostRow(
                        entry,
                        isSelected: isSelected
                    )
                }
                .buttonStyle(PressableCardButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .swipeActions {
                    Button("删除", role: .destructive) {
                        viewStore.send(.deleteHost(entry.id))
                    }
                }
            }
        } label: {
            Text(viewStore.settings.currentHost?.value ?? "未选择域名")
                .lineLimit(1)
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
    SiteSettingsView(
        store: Store(initialState: SiteFeature.State()) {
            SiteFeature()
        },
        guardIsPresented: false,
        lastGuardOutcome: nil,
        onManualGuard: {}
    )
}
