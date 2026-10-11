import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 书架固定的「本地」分组（U5-4）。
///
/// ## 为什么另开一个文件
/// `BookshelfFeatureTests.swift` 已 587 行（`file_length` warning = 600），
/// 再加用例就会越线；既有用例也一律不动（它们是回归基线）。
///
/// ## 这里钉住的是什么
/// 「本地」不进 SwiftData（`BookGroup` 没有「系统固定」标记），它是 `State.showsLocalGroup`
/// 这个**并列的选中状态**，与 `selectedGroupID` 互斥 —— 互斥的不变量由 reducer 保证，
/// 本文件逐条断言它，并顺带回归 `visibleRows` 的既有过滤行为。
@MainActor
final class BookshelfLocalGroupTests: XCTestCase {
    private static func makeRow(bookPath: String, groupID: UUID? = nil) -> ShelfRow {
        ShelfRow(
            bookPath: bookPath,
            title: "书 \(bookPath)",
            author: "某某某",
            coverUrl: "",
            groupId: groupID
        )
    }

    func test选中本地分组会置位本地标记并清空书组选中() async {
        let groupID = UUID()
        let store = TestStore(
            initialState: BookshelfFeature.State(
                rows: [Self.makeRow(bookPath: "/1/", groupID: groupID)],
                selectedGroupID: groupID
            )
        ) {
            BookshelfFeature()
        }

        await store.send(.localGroupSelected) {
            $0.showsLocalGroup = true
            $0.selectedGroupID = nil
        }
        XCTAssertFalse(store.state.isAllSelected, "本地态下「全部」胶囊不能同时高亮")
        await store.finish()
    }

    func test已选中本地时重复点击不改变状态() async {
        // 状态不变时**不能**传尾随闭包：那等于断言「状态变了」，
        // TestStore 会报 "Expected state to change, but no change occurred."
        let store = TestStore(initialState: BookshelfFeature.State(showsLocalGroup: true)) {
            BookshelfFeature()
        }

        await store.send(.localGroupSelected)
        XCTAssertTrue(store.state.showsLocalGroup)
        XCTAssertNil(store.state.selectedGroupID)
        await store.finish()
    }

    func test选中书组会清掉本地标记() async {
        let groupID = UUID()
        let store = TestStore(initialState: BookshelfFeature.State(showsLocalGroup: true)) {
            BookshelfFeature()
        }

        await store.send(.groupSelected(groupID)) {
            $0.selectedGroupID = groupID
            $0.showsLocalGroup = false
        }
        await store.finish()
    }

    func test从本地切回全部会清掉本地标记() async {
        // 「全部」= `selectedGroupID` 为 `nil`，与进入本地之前的值相同；
        // 这一下必须靠 `showsLocalGroup` 判定「有变化」，否则会被幂等守卫吞掉。
        let store = TestStore(initialState: BookshelfFeature.State(showsLocalGroup: true)) {
            BookshelfFeature()
        }

        await store.send(.groupSelected(nil)) {
            $0.showsLocalGroup = false
        }
        XCTAssertTrue(store.state.isAllSelected)
        await store.finish()
    }

    func test新建分组会清掉本地标记() async {
        // 新建后自动选中新分组 ⇒ 与「选中书组」同一条不变量。
        let group = ShelfGroupSnapshot(id: UUID(), name: "玄幻", sortIndex: 0)
        let store = TestStore(initialState: BookshelfFeature.State(showsLocalGroup: true)) {
            BookshelfFeature()
        } withDependencies: {
            $0.shelfGroupStore.createGroup = { _ in group }
        }

        await store.send(.createGroup("玄幻"))
        await store.receive(.groupCreated(group)) {
            $0.groups = [group]
            $0.selectedGroupID = group.id
            $0.showsLocalGroup = false
        }
        await store.finish()
    }

    func test本地态下删除分组仍然停在本地分组() async {
        // 不变量入口复核：`.groupDeleted` 只在「删掉的正是当前选中组」时清 `selectedGroupID`。
        // 本地态下它已是 `nil`，所以这一支既不碰它，也不该把用户踢出本地分组。
        let group = ShelfGroupSnapshot(id: UUID(), name: "玄幻", sortIndex: 0)
        let store = TestStore(
            initialState: BookshelfFeature.State(groups: [group], showsLocalGroup: true)
        ) {
            BookshelfFeature()
        } withDependencies: {
            $0.shelfGroupStore.deleteGroup = { _ in }
        }

        await store.send(.deleteGroup(group.id))
        await store.receive(.groupDeleted(group.id)) {
            $0.groups = []
        }
        XCTAssertTrue(store.state.showsLocalGroup)
        XCTAssertNil(store.state.selectedGroupID)
        await store.finish()
    }

    func test本地分组不影响可见行的书目过滤() async {
        let groupID = UUID()
        let grouped = Self.makeRow(bookPath: "/1/", groupID: groupID)
        let ungrouped = Self.makeRow(bookPath: "/2/")
        let store = TestStore(
            initialState: BookshelfFeature.State(
                rows: [grouped, ungrouped],
                selectedGroupID: groupID
            )
        ) {
            BookshelfFeature()
        }

        XCTAssertEqual(store.state.visibleRows.map(\.bookPath), ["/1/"])

        await store.send(.localGroupSelected) {
            $0.showsLocalGroup = true
            $0.selectedGroupID = nil
        }
        // 「本地」不参与书目过滤：行既没被删、也没被筛掉，过滤退回「全部」。
        XCTAssertEqual(store.state.rows.map(\.bookPath), ["/1/", "/2/"])
        XCTAssertEqual(store.state.visibleRows.map(\.bookPath), ["/1/", "/2/"])
        await store.finish()
    }

    func test既有书组与全部过滤行为未变() async {
        // 回归保护：本地标记只改「选中了什么」，不改过滤本身 ——
        // 选中不存在的分组仍然得到空列表（界面据此显示空态）。
        let groupID = UUID()
        let missingID = UUID()
        let store = TestStore(
            initialState: BookshelfFeature.State(
                rows: [
                    Self.makeRow(bookPath: "/1/", groupID: groupID),
                    Self.makeRow(bookPath: "/2/"),
                ]
            )
        ) {
            BookshelfFeature()
        }

        XCTAssertEqual(store.state.visibleRows.map(\.bookPath), ["/1/", "/2/"])

        await store.send(.groupSelected(groupID)) {
            $0.selectedGroupID = groupID
        }
        XCTAssertEqual(store.state.visibleRows.map(\.bookPath), ["/1/"])

        await store.send(.localGroupSelected) {
            $0.showsLocalGroup = true
            $0.selectedGroupID = nil
        }
        XCTAssertEqual(store.state.visibleRows.map(\.bookPath), ["/1/", "/2/"])

        await store.send(.groupSelected(missingID)) {
            $0.selectedGroupID = missingID
            $0.showsLocalGroup = false
        }
        XCTAssertTrue(store.state.visibleRows.isEmpty)
        await store.finish()
    }

    // MARK: - 选择模式不常驻（owner 2026-10-11 口径）

    /// **切分组 = 进入另一个页面** ⇒ 编辑（选择）模式必须退出、已选必须清空。
    ///
    /// ## 为什么钉在这里
    /// 旧行为是「`.groupSelected` / `.localGroupSelected` 都不碰 `isEditing`」——
    /// 于是长按进编辑态后切个分组，编辑态**跟着过去**（分组栏右边还挂着「完成」、批量工具栏还在），
    /// 看上去像「选择模式被常驻了」。owner 真机口径：**任何离开当前页面的动作都退出选择模式**。
    ///
    /// ⚠️ 视图层还有**另一半**（下载选择模式住在 `DownloadFeature`，书架 reducer 够不到）——
    /// 那一半在 `BookshelfView+GroupBar.swift` 的 `groupChips` 与 `BookshelfView` 的 `.onDisappear` 里，
    /// 本文件覆盖不到，只能靠真机 / UI 层验证。
    func test编辑态下切分组会退出编辑态并清空已选() async {
        let groupID = UUID()
        let store = TestStore(
            initialState: BookshelfFeature.State(
                rows: [Self.makeRow(bookPath: "/1/", groupID: groupID)],
                isEditing: true,
                selectedBookPaths: ["/1/"]
            )
        ) {
            BookshelfFeature()
        }

        await store.send(.localGroupSelected) {
            $0.showsLocalGroup = true
            $0.selectedGroupID = nil
            $0.isEditing = false
            $0.selectedBookPaths = []
        }
        XCTAssertFalse(store.state.isEditing, "切分组后必须已退出编辑态")
        XCTAssertTrue(store.state.selectedBookPaths.isEmpty, "退出编辑态必须连带清空已选")
        await store.finish()
    }

    /// 同一条口径的另一半：`.groupSelected` 也要退出（从「本地」切回「全部」/ 切到某个书组）。
    func test编辑态下切回全部也会退出编辑态() async {
        let groupID = UUID()
        let store = TestStore(
            initialState: BookshelfFeature.State(
                rows: [Self.makeRow(bookPath: "/1/", groupID: groupID)],
                selectedGroupID: groupID,
                isEditing: true,
                selectedBookPaths: ["/1/"]
            )
        ) {
            BookshelfFeature()
        }

        await store.send(.groupSelected(nil)) {
            $0.selectedGroupID = nil
            $0.isEditing = false
            $0.selectedBookPaths = []
        }
        XCTAssertFalse(store.state.isEditing, "切回「全部」同样要退出编辑态")
        await store.finish()
    }

    /// 反向守卫：**没在编辑态**时切分组不该多出状态变化（幂等，且不能把 `isEditing` 写成别的值）。
    func test非编辑态切分组不产生额外状态变化() async {
        let groupID = UUID()
        let store = TestStore(
            initialState: BookshelfFeature.State(rows: [Self.makeRow(bookPath: "/1/", groupID: groupID)])
        ) {
            BookshelfFeature()
        }

        await store.send(.groupSelected(groupID)) {
            $0.selectedGroupID = groupID
        }
        XCTAssertFalse(store.state.isEditing)
        await store.finish()
    }

    /// **点的是当前分组**同样要退出编辑态 —— 这条是「复位必须放在幂等 guard **之前**」的直接判据。
    ///
    /// 若把复位写在 guard 之后，那条 guard 会先 `return .none`，用户在编辑态下点同一个分组就**退不出来**。
    func test编辑态下点当前分组也会退出编辑态() async {
        let groupID = UUID()
        let store = TestStore(
            initialState: BookshelfFeature.State(
                rows: [Self.makeRow(bookPath: "/1/", groupID: groupID)],
                selectedGroupID: groupID,
                isEditing: true,
                selectedBookPaths: ["/1/"]
            )
        ) {
            BookshelfFeature()
        }

        // 分组没变（幂等 guard 命中）⇒ 期望态里**没有** `selectedGroupID` 的变化，但编辑态必须退。
        await store.send(.groupSelected(groupID)) {
            $0.isEditing = false
            $0.selectedBookPaths = []
        }
        XCTAssertEqual(store.state.selectedGroupID, groupID, "点当前分组不该改动分组本身")
        XCTAssertFalse(store.state.isEditing, "点当前分组同样要退出编辑态")
        XCTAssertTrue(store.state.selectedBookPaths.isEmpty)
        await store.finish()
    }
}
