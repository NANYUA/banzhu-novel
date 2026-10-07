import ComposableArchitecture
import NovelCore
import SwiftUI

/// App 入口界面。
///
/// 当前提供书架与搜索两个入口，搜索成功后由书架在下次出现时重新加载。
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

            SearchView(store: searchStore)
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
        }
    }
}

#Preview {
    RootView()
}
