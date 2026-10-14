import NovelCore
import NovelEngine
import SwiftUI

// 阅读页右上「更多」菜单里的「加入书架」：查一次「这本书在不在书架」，以及点它时加入书架。
//
// ## 为什么单独一个文件
// 这一块（一个 `@State` + 两个 async 动作）只服务那一个菜单项，与上栏 / 下栏 / 跳章条 /
// 正文零耦合；而 `ReaderView+Chrome.swift` 加完接线后余量已经不多，`file_length` 600 是
// CI 硬门（`--strict` ⇒ warning 即失败）。拆法沿用既有先例
// （`ReaderView+MoreMenu.swift` 与 `BookshelfView+GroupBar.swift` 的文件头同一条理由）。
// 代价与先例相同：`ReaderChromeOverlay.isOnShelf` 不能再是 `private`
// —— Swift 的 `private` 是本文件级的，跨文件 extension 读不到。

extension ReaderChromeOverlay {
    /// 查一次「这本书在不在书架」，结果回写到 `isOnShelf`（菜单项据此显示 / 置灰）。
    ///
    /// 判据只有一条：库里有没有这本书的 `BookRecord`（`ShelfMembership.contains`，
    /// 与 `ShelfAdderLive.add` 的查重是同一个 `#Predicate`）。
    /// 由 `ReaderChromeOverlay.body` 的 `.task` 在控制栏出现时跑一次。
    ///
    /// 显式 `@MainActor`：`.task` 的闭包是 `@Sendable`，`await` 之后不保证回到主线程，
    /// 而这里要写 `@State`（同 `BookshelfView+Reader.swift` 里 `openReader` 的处置与理由）。
    @MainActor
    func refreshShelfMembership() async {
        isOnShelf = await shelfMembership.contains(bookPath)
    }

    /// 「加入书架」：加入成功后菜单项**立刻**变成置灰的「已在书架」。
    ///
    /// 面板此刻已经收起（`selectMoreMenuItem` 的「先收面板、再执行动作」），所以这次回写
    /// 只影响**下次**打开面板时的那三项目 —— `isOnShelf` 一改，
    /// `ReaderMoreMenuItem.readerMoreMenu` 的数组就跟着重算。
    /// 失败（`false`）**什么都不做**：菜单项维持「加入书架」，再点一次即可。
    ///
    /// 同步签名 + 内部 `Task { @MainActor in }`：菜单项的 `action` 是 `() -> Void`
    /// （`selectMoreMenuItem` 同步调用它），而落库要走 `async` 依赖；方法本身**不能**标
    /// `@MainActor` —— 那会让 `addBookToShelf` 变成 `@MainActor () -> Void`，
    /// 传给 `onAddToShelf: () -> Void` 就是丢全局 actor。所以把 `@MainActor` 收进 `Task` 里。
    func addBookToShelf() {
        Task { @MainActor in
            let book = Book(path: bookPath, title: bookTitle)
            if await shelfMembership.add(book) {
                isOnShelf = true
            }
        }
    }
}
