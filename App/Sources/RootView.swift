import ComposableArchitecture
import NovelCore
import SwiftUI

/// App 入口界面。
///
/// 当前展示书架（交接文档第 3 步）。后续在此之下展开书城/搜索/阅读器。
struct RootView: View {
    var body: some View {
        BookshelfView(
            store: Store(initialState: BookshelfFeature.State()) {
                BookshelfFeature()
            }
        )
    }
}
