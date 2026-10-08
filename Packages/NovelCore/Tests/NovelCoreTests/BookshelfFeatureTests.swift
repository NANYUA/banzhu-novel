import ComposableArchitecture
import Foundation
@testable import NovelCore
import NovelEngine
import XCTest

/// 书架 reducer 的测试。
///
/// D2 选 TCA 的理由之一是「喂一串 Action 断言状态，不用启动界面」——
/// 这个文件就是那句话的兑现证明：全程没有 `ModelContainer`、没有 View、
/// 没有真数据，只有「喂一串 Action → 断言状态」。
@MainActor
final class BookshelfFeatureTests: XCTestCase {
    /// 固定时间戳，避免断言随 `Date()` 漂移
    private static let readAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeRow(bookPath: String, title: String) -> ShelfRow {
        ShelfRow(
            bookPath: bookPath,
            title: title,
            author: "某某某",
            coverUrl: "https://example.com/cover.jpg",
            lastReadChapterName: "第 123 章 章节名",
            latestChapterName: "第 131 章 章节名",
            unreadCount: 8,
            lastReadAt: readAt
        )
    }

    private static func makeGroup(id: UUID, name: String, sortIndex: Int) -> ShelfGroupSnapshot {
        ShelfGroupSnapshot(id: id, name: name, sortIndex: sortIndex)
    }

    private func makeStore(
        initialState: BookshelfFeature.State = BookshelfFeature.State(),
        rows: @escaping @Sendable () async throws -> [ShelfRow] = { [] },
        groups: @escaping @Sendable () async throws -> [ShelfGroupSnapshot] = { [] },
        groupStore: ShelfGroupStore? = nil,
        batchDownloader: ShelfBatchDownloader? = nil
    ) -> TestStore<BookshelfFeature.State, BookshelfFeature.Action> {
        TestStore(initialState: initialState) {
            BookshelfFeature()
        } withDependencies: {
            $0.shelfLoader.load = rows
            if let groupStore {
                $0.shelfGroupStore = groupStore
            } else {
                $0.shelfGroupStore.loadGroups = groups
            }
            if let batchDownloader {
                $0.shelfBatchDownloader = batchDownloader
            }
        }
    }

    private func makeGroupStore(
        loadGroups: @escaping @Sendable () async throws -> [ShelfGroupSnapshot] = { [] },
        createGroup: @escaping @Sendable (String) async throws -> ShelfGroupSnapshot = { name in
            ShelfGroupSnapshot(id: UUID(), name: name, sortIndex: 0)
        },
        renameGroup: @escaping @Sendable (UUID, String) async throws -> Void = { _, _ in },
        deleteGroup: @escaping @Sendable (UUID) async throws -> Void = { _ in },
        assignBooks: @escaping @Sendable ([String], UUID?) async throws -> Void = { _, _ in },
        removeBooks: @escaping @Sendable ([String]) async throws -> Void = { _ in }
    ) -> ShelfGroupStore {
        ShelfGroupStore(
            loadGroups: loadGroups,
            createGroup: createGroup,
            renameGroup: renameGroup,
            deleteGroup: deleteGroup,
            assignBooks: assignBooks,
            removeBooks: removeBooks
        )
    }

    func test加载成功填入行且结束加载态() async {
        let rows = [Self.makeRow(bookPath: "/49/49034/", title: "楚香君游戏")]
        let store = makeStore(rows: { rows })

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded(rows)) {
            $0.rows = rows
            $0.isLoading = false
        }
        await store.receive(.groupsLoaded([]))
        await store.finish()
    }

    func test加载分组成功() async {
        let group = Self.makeGroup(id: UUID(), name: "玄幻", sortIndex: 0)
        let store = makeStore(groups: { [group] })

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded([])) {
            $0.isLoading = false
        }
        await store.receive(.groupsLoaded([group])) {
            $0.groups = [group]
        }
        await store.finish()
    }

    func test选择分组过滤书架() async {
        let groupID = UUID()
        let grouped = ShelfRow(
            bookPath: "/1/",
            title: "分组书",
            author: "",
            coverUrl: "",
            groupId: groupID
        )
        let ungrouped = Self.makeRow(bookPath: "/2/", title: "未分组书")
        let store = makeStore(rows: { [grouped, ungrouped] })

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded([grouped, ungrouped])) {
            $0.rows = [grouped, ungrouped]
            $0.isLoading = false
        }
        await store.receive(.groupsLoaded([]))
        await store.finish()

        await store.send(.groupSelected(groupID)) {
            $0.selectedGroupID = groupID
        }
        XCTAssertEqual(store.state.visibleRows.map(\.bookPath), ["/1/"])
    }

    func test加载失败记录原因且不假装空书架() async {
        struct LoadFailed: Error {}

        let store = makeStore(rows: { throw LoadFailed() })

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        // rows 保持为空但 errorMessage 非空 —— 界面据此显示「加载失败」而不是「空书架」
        await store.receive(.loadFailed("LoadFailed()")) {
            $0.errorMessage = "LoadFailed()"
            $0.isLoading = false
        }
        await store.receive(.groupsLoaded([]))
        await store.finish()
    }

    func test创建分组成功后加入并自动选中() async {
        let group = Self.makeGroup(id: UUID(), name: "玄幻", sortIndex: 0)
        let store = makeStore(groupStore: makeGroupStore(createGroup: { name in
            XCTAssertEqual(name, "玄幻")
            return group
        }))

        await store.send(.createGroup(" 玄幻 "))
        await store.receive(.groupCreated(group)) {
            $0.groups = [group]
            $0.selectedGroupID = group.id
        }
        await store.finish()
    }

    func test创建空分组名给出提示且不产生请求() async {
        let store = makeStore()

        await store.send(.createGroup("   ")) {
            $0.groupNotice = "分组名不能为空。"
        }
        await store.finish()
    }

    func test重命名分组更新列表() async {
        let groupID = UUID()
        let store = makeStore(
            initialState: BookshelfFeature.State(groups: [
                Self.makeGroup(id: groupID, name: "旧名", sortIndex: 0),
            ]),
            groupStore: makeGroupStore(renameGroup: { id, name in
                XCTAssertEqual(id, groupID)
                XCTAssertEqual(name, "新名")
            })
        )

        await store.send(.renameGroup(groupID, "新名"))
        await store.receive(.groupRenamed(groupID, "新名")) {
            $0.groups = [Self.makeGroup(id: groupID, name: "新名", sortIndex: 0)]
        }
        await store.finish()
    }

    func test删除分组后书回到未分组() async {
        let groupID = UUID()
        let grouped = ShelfRow(
            bookPath: "/1/",
            title: "分组书",
            author: "",
            coverUrl: "",
            groupId: groupID
        )
        let store = makeStore(
            initialState: BookshelfFeature.State(
                rows: [grouped],
                groups: [Self.makeGroup(id: groupID, name: "旧组", sortIndex: 0)],
                selectedGroupID: groupID
            ),
            groupStore: makeGroupStore(deleteGroup: { id in
                XCTAssertEqual(id, groupID)
            })
        )

        await store.send(.deleteGroup(groupID))
        await store.receive(.groupDeleted(groupID)) {
            $0.groups = []
            $0.selectedGroupID = nil
        }
        XCTAssertEqual(store.state.visibleRows.map(\.bookPath), ["/1/"])
        await store.finish()
    }
}

// MARK: - 批量操作

@MainActor extension BookshelfFeatureTests {
    func test批量归类更新选中书的groupId() async {
        let groupID = UUID()
        let rowA = Self.makeRow(bookPath: "/1/", title: "书一")
        let rowB = Self.makeRow(bookPath: "/2/", title: "书二")
        let store = makeStore(
            initialState: BookshelfFeature.State(
                rows: [rowA, rowB],
                isEditing: true,
                selectedBookPaths: ["/1/"]
            ),
            groupStore: makeGroupStore(assignBooks: { paths, target in
                XCTAssertEqual(paths, ["/1/"])
                XCTAssertEqual(target, groupID)
            })
        )

        await store.send(.assignSelectedBooks(groupID))
        await store.receive(.booksGroupAssigned(groupID)) {
            $0.rows[0].groupId = groupID
        }
        XCTAssertEqual(store.state.rows.first(where: { $0.bookPath == "/1/" })?.groupId, groupID)
        XCTAssertNil(store.state.rows.first(where: { $0.bookPath == "/2/" })?.groupId)
        await store.finish()
    }

    func test批量删除移除行与选中项() async {
        let rowA = Self.makeRow(bookPath: "/1/", title: "书一")
        let rowB = Self.makeRow(bookPath: "/2/", title: "书二")
        let store = makeStore(
            initialState: BookshelfFeature.State(
                rows: [rowA, rowB],
                isEditing: true,
                selectedBookPaths: ["/1/", "/2/"]
            ),
            groupStore: makeGroupStore(removeBooks: { paths in
                XCTAssertEqual(Set(paths), Set(["/1/", "/2/"]))
            })
        )

        await store.send(.deleteSelectedBooks)
        await store.receive(.booksDeleted(["/1/", "/2/"])) {
            $0.rows = []
            $0.selectedBookPaths = []
            $0.isEditing = false
        }
        await store.finish()
    }

    func test批量下载准备请求并暂存() async {
        let request = DownloadChapterRequest(
            bookPath: "/1/",
            bookTitle: "书一",
            chapterPath: "/1/1.html",
            chapterName: "第 1 章",
            chapterNumber: 1
        )
        let store = makeStore(
            initialState: BookshelfFeature.State(
                rows: [Self.makeRow(bookPath: "/1/", title: "书一")],
                isEditing: true,
                selectedBookPaths: ["/1/"]
            ),
            batchDownloader: ShelfBatchDownloader { paths in
                XCTAssertEqual(paths, ["/1/"])
                return [request]
            }
        )

        await store.send(.downloadSelectedBooks)
        await store.receive(.batchDownloadPrepared([request])) {
            $0.pendingDownloadRequests = [request]
        }
        await store.send(.batchDownloadConsumed) {
            $0.pendingDownloadRequests = []
        }
        await store.finish()
    }

    func test没有选中书时批量操作直接忽略() async {
        let store = makeStore(
            initialState: BookshelfFeature.State(
                rows: [Self.makeRow(bookPath: "/1/", title: "书一")],
                isEditing: true
            )
        )

        await store.send(.assignSelectedBooks(nil))
        await store.send(.deleteSelectedBooks)
        await store.send(.downloadSelectedBooks)
        await store.finish()
    }

    func test加载中重复触发被忽略() async {
        // 直接以「正在加载」为初值，模拟「视图已经发过一次 onAppear 又发了一次」
        // （导航返回、scenePhase 变化都会造成这种重复触发）
        let store = makeStore(
            initialState: BookshelfFeature.State(isLoading: true)
        )

        // 守卫生效 → 不产生任何 effect，也就没有后续 action 需要处理。
        // 守卫若失效，这里会多出一个 .run 效果并拉一次数据，断言会失败。
        await store.send(.onAppear)
        await store.finish()
    }
}

@MainActor extension BookshelfFeatureTests {
    // MARK: - 加入书架

    private static func makeBook(path: String, title: String) -> Book {
        Book(path: path, title: title)
    }

    func test加入书架成功后插到列表最前() async {
        let existing = Self.makeRow(bookPath: "/1/", title: "已有的书")
        let newRow = Self.makeRow(bookPath: "/2/", title: "新加的书")
        let book = Self.makeBook(path: "/2/", title: "新加的书")

        let store = TestStore(initialState: BookshelfFeature.State(rows: [existing])) {
            BookshelfFeature()
        } withDependencies: {
            $0.shelfAdder.add = { _ in newRow }
        }

        await store.send(.addRequested(book)) {
            $0.addingCount = 1
        }
        await store.receive(.addSucceeded(newRow)) {
            $0.addingCount = 0
            $0.rows = [newRow, existing]
        }
        await store.finish()
    }

    func test加入已存在的书给出人话提示() async {
        let book = Self.makeBook(path: "/1/", title: "已有的书")

        let store = TestStore(initialState: BookshelfFeature.State()) {
            BookshelfFeature()
        } withDependencies: {
            $0.shelfAdder.add = { _ in
                throw ShelfAdderError.alreadyExists(title: "已有的书")
            }
        }

        await store.send(.addRequested(book)) {
            $0.addingCount = 1
        }
        // 用 localizedDescription：错误信息必须是「《X》已经在书架里了」这种用户能读的话，
        // 而不是 `alreadyExists(title: "X")` 这种代码腔
        await store.receive(.addFailed("《已有的书》已经在书架里了。")) {
            $0.addingCount = 0
            $0.addNotice = "《已有的书》已经在书架里了。"
        }

        await store.send(.noticeDismissed) {
            $0.addNotice = nil
        }
        await store.finish()
    }

    func test顺序加入两本时加载态逐次清零() async {
        // 顺序交替：发第一本 → 收到成功 → 发第二本 → 收到成功。
        // 严格交替能断言每一步的 addingCount 精确值。
        // （真并发需要 .merge 或 .debounce，当前需求用不上。）
        let book1 = Self.makeBook(path: "/1/", title: "书一")
        let book2 = Self.makeBook(path: "/2/", title: "书二")
        let row1 = Self.makeRow(bookPath: "/1/", title: "书一")
        let row2 = Self.makeRow(bookPath: "/2/", title: "书二")

        let store = TestStore(initialState: BookshelfFeature.State()) {
            BookshelfFeature()
        } withDependencies: {
            $0.shelfAdder.add = { book in
                book.path == "/1/" ? row1 : row2
            }
        }

        await store.send(.addRequested(book1)) {
            $0.addingCount = 1
        }
        await store.receive(.addSucceeded(row1)) {
            $0.addingCount = 0
            $0.rows = [row1]
        }
        await store.send(.addRequested(book2)) {
            $0.addingCount = 1
        }
        await store.receive(.addSucceeded(row2)) {
            $0.addingCount = 0
            $0.rows = [row2, row1]
        }
        await store.finish()
    }

    func test重复收到同一本的成功不会插重复() async {
        // 并发场景下同一本书可能被加两次，第二次不应在列表里出现两行
        let row = Self.makeRow(bookPath: "/1/", title: "书一")

        let store = TestStore(initialState: BookshelfFeature.State(rows: [row])) {
            BookshelfFeature()
        }

        await store.send(.addSucceeded(row))
        await store.finish()
        XCTAssertEqual(store.state.rows.count, 1, "重复加入产生了重复行")
    }

    func test新请求会清掉上一次的提示() async {
        let book = Self.makeBook(path: "/1/", title: "书一")
        let row = Self.makeRow(bookPath: "/1/", title: "书一")

        let store = TestStore(
            initialState: BookshelfFeature.State(addNotice: "上一次的提示")
        ) {
            BookshelfFeature()
        } withDependencies: {
            $0.shelfAdder.add = { _ in row }
        }

        await store.send(.addRequested(book)) {
            $0.addingCount = 1
            $0.addNotice = nil
        }
        await store.receive(.addSucceeded(row)) {
            $0.addingCount = 0
            $0.rows = [row]
        }
        await store.finish()
    }
}

/// 书架排序。
///
/// 需求 docs/03 §2.1 只写了「按最近阅读时间倒序」，
/// 另外两条（未读沉底、同档按加入时间）是在落地时补的，这里逐条钉住。
final class ShelfOrderTests: XCTestCase {
    func test最近读过的排最前() {
        let old = BookRecord(bookPath: "/1/", title: "很久没读")
        old.lastReadAt = Date(timeIntervalSince1970: 1000)
        let recent = BookRecord(bookPath: "/2/", title: "刚读过")
        recent.lastReadAt = Date(timeIntervalSince1970: 9000)

        let sorted = [old, recent].sorted(by: ShelfOrder.isBefore)
        XCTAssertEqual(sorted.map(\.bookPath), ["/2/", "/1/"])
    }

    func test没读过的排最后() {
        let never = BookRecord(bookPath: "/1/", title: "没读过")
        let read = BookRecord(bookPath: "/2/", title: "读过")
        read.lastReadAt = Date(timeIntervalSince1970: 1000)

        let sorted = [never, read].sorted(by: ShelfOrder.isBefore)
        XCTAssertEqual(sorted.map(\.bookPath), ["/2/", "/1/"])
    }

    func test同一档按加入时间倒序() {
        // 两本都没读过 → lastReadAt 都是 nil，必须靠 addedAt 分出先后，
        // 否则每次 fetch 的返回顺序一变，书架就跟着抖
        let older = BookRecord(bookPath: "/1/", title: "先加的", addedAt: Date(timeIntervalSince1970: 1000))
        let newer = BookRecord(bookPath: "/2/", title: "后加的", addedAt: Date(timeIntervalSince1970: 2000))

        let sorted = [older, newer].sorted(by: ShelfOrder.isBefore)
        XCTAssertEqual(sorted.map(\.bookPath), ["/2/", "/1/"])
    }
}
