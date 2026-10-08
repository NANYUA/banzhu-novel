import ComposableArchitecture
import NovelCore
import SwiftUI

/// App 入口界面。
///
/// 当前提供书架与搜索两个入口，搜索加书成功后即时同步书架状态。
struct RootView: View {
    @State private var bookshelfStore = Store(initialState: BookshelfFeature.State()) {
        BookshelfFeature()
    }

    @State private var searchStore = Store(initialState: SearchFeature.State()) {
        SearchFeature()
    }

    var body: some View {
        TabView {
            BookshelfView(store: bookshelfStore)
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }

            SearchView(store: searchStore) { row in
                bookshelfStore.send(.addSucceeded(row))
            }
            .tabItem {
                Label("搜索", systemImage: "magnifyingglass")
            }
        }
    }
}

#Preview {
    RootView()
}
