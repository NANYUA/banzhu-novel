import ComposableArchitecture
import NovelCore
import SwiftUI

/// 下载**进行中**时，详情页「已下载」标记的就地刷新（owner 选定的方案 B）。
///
/// ## 为什么是「观察队列 + 就地打标」
/// `DownloadFeature.State.completedChapterPaths(forBook:)` 是**纯内存**派生值：队列状态一变它跟着变。
/// 这里只观察它，把**新增**完成的 chapterPath 回传给
/// `BookDetailFeature.Action.chaptersDownloaded` —— 一次数据库读都不增加。
///
/// 被否决的做法是在 `DownloadFeature.State.finishedCount` 上挂 `onChange` 触发
/// `.reloadChapters`：500 章批量下载会变成 500 次整本目录读（O(n²)）。
extension BookDetailView {
    /// 不可见观察者：挂在页面背景上（透明、不接受点击），不产出任何界面，
    /// 只把新完成的章节路径回传 reducer。
    ///
    /// 用 `WithViewStore` 观察派生值（`DownloadFeature.State` 不是 `ObservableState`，
    /// 视图层不能读 `store.state`）。
    func downloadCompletionObserver(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        // 本书的过滤由 NovelCore 的派生值负责：这一层既不拼也不拆
        // `bookPath#chapterPath` 复合键，键格式变化不会在这里静默失配。
        let bookPath = viewStore.detail.bookPath
        return WithViewStore(
            downloadStore,
            observe: { $0.completedChapterPaths(forBook: bookPath) }
        ) { downloadViewStore in
            Color.clear
                // 纯观察者：不接受点击，不能抢走页面的手势。
                .allowsHitTesting(false)
                .onChange(of: downloadViewStore.state) { oldPaths, newPaths in
                    let paths = newChapterPaths(from: oldPaths, to: newPaths)
                    guard !paths.isEmpty else { return }
                    viewStore.send(.chaptersDownloaded(paths))
                }
        }
    }
}

/// 只取**新增**完成的 chapterPath（`newPaths` 减去 `oldPaths`），
/// 避免每次队列变化都把这本书的全部已完成项重发一遍。
private func newChapterPaths(from oldPaths: Set<String>, to newPaths: Set<String>) -> [String] {
    newPaths.subtracting(oldPaths).sorted()
}
