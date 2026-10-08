import ComposableArchitecture
import NovelCore
import SwiftUI

/// App 入口界面。
///
/// 当前提供书架、搜索与下载三个入口，搜索加书成功后即时同步书架状态。
struct RootView: View {
    @State private var bookshelfStore = Store(initialState: BookshelfFeature.State()) {
        BookshelfFeature()
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
        TabView {
            BookshelfView(store: bookshelfStore, downloadStore: downloadStore)
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }

            SearchView(store: searchStore) { row in
                bookshelfStore.send(.addSucceeded(row))
            }
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
        .overlay {
            GuardOverlayView(store: guardStore)
                .allowsHitTesting(guardStore.state.isPresented)
        }
        .task {
            siteStore.send(.task)
            guardStore.send(.task)
            downloadStore.send(.task)
        }
    }
}

#Preview {
    RootView()
}
