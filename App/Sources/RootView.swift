import ComposableArchitecture
import NovelCore
import SwiftUI

/// App 入口界面。
///
/// 当前提供书架、书城、搜索、下载与设置五个入口，
/// 搜索 / 书城加书成功后即时同步书架状态。
struct RootView: View {
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

    var body: some View {
        WithViewStore(guardStore, observe: \.isPresented) { viewStore in
            TabView {
                BookshelfView(store: bookshelfStore, downloadStore: downloadStore)
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
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }

                DownloadQueueView(store: downloadStore)
                    .tabItem {
                        Label("下载", systemImage: "arrow.down.circle")
                    }

                SiteSettingsView(store: siteStore)
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }
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
