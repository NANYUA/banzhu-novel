import ComposableArchitecture
import NovelCore
import SwiftUI

/// 站点入口管理页（手动模式）。
///
/// ## 「域名 / 手动过验证 / 目录正则」三张卡统一口径（owner 2026-10-17 真机反馈）
/// 三张卡**各只有一行**、结构相同：左侧标题 + 右侧当前值（次级色）+ 行高 ≥ 44pt。
/// 因此：域名列表与「添加域名」都搬进二级页（`HostSettingsView`），
/// 目录正则也进二级页（`ImportRulesView`），首页不再出现输入框 / 图标 / 多行内容。
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

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                Form {
                    navigationSection(viewStore)
                    hostSection(viewStore)
                    manualGuardSection(viewStore)
                    rulesSection()

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

    // MARK: - 导航地址

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
                Text("本次发现 \(viewStore.discoveredHosts.count) 个域名，已并入域名列表")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 三张统一卡片

    /// 首页「三个入口」的统一行长：标题 + 右侧值（次级色）+ 44pt 行高。
    private func settingRow(_ title: String, value: String?) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func hostSection(
        _ viewStore: ViewStore<SiteFeature.State, SiteFeature.Action>
    ) -> some View {
        Section {
            NavigationLink {
                HostSettingsView(store: store)
            } label: {
                settingRow(
                    "域名",
                    value: viewStore.settings.currentHost?.value ?? "未选择"
                )
            }
        }
    }

    /// 「手动过验证」：随时主动触发一次人机验证，不必等盾页自己弹出来。
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
                settingRow("手动过验证", value: guardValue(isAvailable: isAvailable))
                    // 自定义 `ButtonStyle` 不会自己变灰（同 `DownloadSelectionCard` 的口径）：
                    // 不可用时整行换次级色，避免「看着能点却没反应」。
                    .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
            }
            .buttonStyle(PressableCardButtonStyle(
                shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
            ))
            .disabled(!isAvailable)
            .accessibilityLabel(isAvailable ? "手动过验证" : "手动过验证，不可用")
        }
    }

    private func guardValue(isAvailable: Bool) -> String? {
        if guardIsPresented {
            return "验证中"
        }
        if !isAvailable {
            return "先选域名"
        }
        if let outcome = lastGuardOutcome {
            return outcome ? "已通过" : "未通过"
        }
        return nil
    }

    /// 「目录正则」：导入 txt 时认章标题的规则管理。
    ///
    /// 为什么放在设置页而不是导入 sheet 里：规则是**一次性配好、长期复用**的配置，
    /// 导入 sheet 是每次都要走一遍的流程页；把管理入口塞进流程页会让「导入」这件事变重。
    /// owner 2026-10-17：卡片行前**不要图标**，标题就叫「目录正则」。
    private func rulesSection() -> some View {
        Section {
            NavigationLink {
                ImportRulesView()
            } label: {
                settingRow("目录正则", value: nil)
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
