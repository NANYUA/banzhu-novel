import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// App 入口界面。
///
/// 当前提供书架、书城、搜索与设置四个入口，
/// 搜索 / 书城加书成功后即时同步书架状态。
///
/// U5-4：底栏的「下载」入口摘掉，下载队列改为书架里的固定「本地」分组
/// （`BookshelfView` → `State.showsLocalGroup` → 复用 `DownloadQueueView`）。
/// 四个 tab 的**类型化**标识。
///
/// 用枚举而不是 `Int` 索引：① 以后在中间插一个 tab 不会让选中项错位；
/// ② `.onChange(of: selectedTab)` 的判据读起来就是「切了 tab」，不是「某个数字变了」。
private enum RootTab: Hashable {
    case bookshelf
    case explore
    case search
    case settings
}

struct RootView: View {
    /// 当前 tab。`TabView(selection:)` 需要一个绑定 —— 它也是「切 tab」这条口径的判据来源
    /// （见 `body` 里 `.onChange(of: selectedTab)`）。
    @State private var selectedTab: RootTab = .bookshelf

    @State private var bookshelfStore = Store(initialState: BookshelfFeature.State()) {
        BookshelfFeature()
    }

    @State private var exploreStore = Store(initialState: ExploreFeature.State()) {
        ExploreFeature()
    }

    @State private var searchStore = Store(initialState: SearchFeature.State()) {
        SearchFeature()
    }

    @State private var downloadStore = Store(initialState: DownloadFeature.State()) {
        DownloadFeature()
    }

    @State private var siteStore = Store(initialState: SiteFeature.State()) {
        SiteFeature()
    }

    @State private var guardStore = Store(initialState: GuardFeature.State()) {
        GuardFeature()
    }

    /// 最近一次**由设置页按钮触发**的验证结果（`GuardCoordinator.requestPass` 的返回值）。
    /// 只作设置页的行内反馈 —— 验证会话本身的真相仍在 `GuardCoordinator` / `guardStore`，
    /// 这里不新建第二份业务状态（「正在验证」直接读 `guardStore` 的 `isPresented`）。
    @State private var lastGuardOutcome: Bool?

    var body: some View {
        WithViewStore(guardStore, observe: \.isPresented) { viewStore in
            TabView(selection: $selectedTab) {
                BookshelfView(store: bookshelfStore, downloadStore: downloadStore)
                    .tag(RootTab.bookshelf)
                    .tabItem {
                        Label("书架", systemImage: "books.vertical")
                    }

                ExploreView(
                    store: exploreStore,
                    downloadStore: downloadStore,
                    onBookAdded: { row in
                        bookshelfStore.send(.addSucceeded(row))
                    },
                    onBookRemoved: { bookPath in
                        // 详情页（从书城进入）移出书架后，书架列表也要立刻摘掉这一行。
                        // 与搜索 tab 走同一条同步路径，不新造单本移除的状态迁移。
                        bookshelfStore.send(.booksDeleted([bookPath]))
                    }
                )
                .tag(RootTab.explore)
                .tabItem {
                    Label("书城", systemImage: "square.grid.2x2")
                }

                SearchView(
                    store: searchStore,
                    downloadStore: downloadStore,
                    onBookAdded: { row in
                        bookshelfStore.send(.addSucceeded(row))
                    },
                    onBookRemoved: { bookPath in
                        // 详情页（从搜索进入）移出书架后，书架列表也要立刻摘掉这一行。
                        // 复用书架批量删除的完成 action，不新造单本移除的状态迁移。
                        bookshelfStore.send(.booksDeleted([bookPath]))
                    }
                )
                .tag(RootTab.search)
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }

                // U5-4：「下载」不再是底栏的一项 —— 入口搬进了书架的固定「本地」分组
                // （`BookshelfView` 在 `showsLocalGroup` 时复用整页 `DownloadQueueView`）。
                // ⚠️ `downloadStore` 仍然要传给书架 / 书城 / 搜索，只是不再单独占一个 tab。
                SiteSettingsView(
                    store: siteStore,
                    guardIsPresented: viewStore.state,
                    lastGuardOutcome: lastGuardOutcome,
                    onManualGuard: {
                        // 与网络层命中盾时**同一条入口**：`SiteFeature` 的 `SiteRouter`
                        // 里 `guardPass` 也是调 `GuardCoordinator.requestPass`
                        // ⇒ 同一个事件流、同一个 `.requested` action，不另造第二条触发路径。
                        // 站点地址取引擎当前生效的 host（与真实请求同一份来源），不在这里再拼一份。
                        lastGuardOutcome = nil
                        Task { @MainActor in
                            let siteURL = await NovelEngine.shared.currentHost()
                            lastGuardOutcome = await GuardCoordinator.shared.requestPass(siteURL: siteURL)
                        }
                    }
                )
                .tag(RootTab.settings)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
            }
            // owner 2026-10-11 口径：**选择模式不常驻** —— 切 tab 就退出（两种模式一起退）。
            //
            // ## 为什么挂在 `TabView` 上、而不是某个 tab 内部
            // 挂在容器上，「离开」与「回来」两侧都覆盖；挂在某个 tab 的 `.onAppear` / `.onDisappear` 里
            // 就只能覆盖那一侧，而且以后加 tab 还得记得补一遍。
            //
            // ## 为什么两种模式都要发
            // 书架编辑态住在 `BookshelfFeature`、下载选择模式住在 `DownloadFeature`（两个独立 store），
            // 而这一层**两个 store 都有** ⇒ 跨 feature 的收口点就在这里。
            // 两个 action 都**幂等**（`editModeChanged` 有 `guard isEditing != state.isEditing`；
            // `applySelectionMode(false)` 同理）⇒ 不在选择模式时切 tab 不产生任何状态变更。
            .onChange(of: selectedTab) { _, _ in
                bookshelfStore.send(.editModeChanged(false))
                downloadStore.send(.selectionModeChanged(false))
            }
            // §6：品牌强调色集中定义在 `AppTheme`，这里一次性注入环境，
            // 系统控件（`.borderedProminent` 填充、分段控件、开关、搜索框、
            // 标签栏选中项）与所有 `.foregroundStyle(.tint)` 自动跟随，
            // 不再逐视图刷色。
            .tint(AppTheme.accent)
            // §10 / §12：验证是打断式的全屏任务，用 fullScreenCover 拿到真正的模态语义
            // （VoiceOver 焦点隔离、底层内容不可点），替代原先无模态语义的 overlay。
            // 关闭（返回 / 取消 / 手势外的程序化 dismissal）统一走 .cancelled。
            .fullScreenCover(
                isPresented: Binding(
                    get: { viewStore.state },
                    set: { isPresented in
                        if !isPresented {
                            guardStore.send(.cancelled)
                        }
                    }
                )
            ) {
                GuardOverlayView(store: guardStore)
            }
            .task {
                siteStore.send(.task)
                guardStore.send(.task)
                downloadStore.send(.task)
            }
        }
    }
}

#Preview {
    RootView()
}
