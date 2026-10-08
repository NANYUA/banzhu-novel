import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 书架（docs/03 §二 · §三）。
///
/// ## 这一层只管状态，不管界面
/// `check-architecture.sh` 规则 1 禁止 `Packages/` 内 `import SwiftUI`，
/// 所以 **Reducer 住 NovelCore、View 住 App**，两边靠 `StoreOf<BookshelfFeature>`
/// 的类型对接。这是那条约束第一次真正生效的地方。
///
/// ## 为什么不用 @Reducer / @ObservableState 宏
/// Xcode 16.4（macos-15 runner）下，TCA 1.23.0 的宏插件在 xcodebuild 里
/// 始终报 "produced malformed response"（两层 `-skip*Validation` 都不管用），
/// 而 `swift test`（SwiftPM）能正常跑宏。
///
/// 这个项目不能依赖「CI runner 恰好能跑宏」—— 宏在本地 Xcode 版本、
/// 未来 Xcode 升级时都可能静默失效，**正确性不能靠运行时假设担保**。
/// 手写 Reducer 协议多 3 行，换来的是「任何 Swift 编译器都能编译」。
///
/// 唯一保留的宏特性是 `@Dependency`——它是 property wrapper，不是宏，
/// 不经过编译器插件，xcodebuild 和 swift 都能正常处理。
public struct BookshelfFeature: Reducer {
    public init() {}

    /// 🔴 必须显式 `: Equatable`：`TestStore.receive(_:)` 活在
    /// `extension TestStore where Action: Equatable` 里 —— 不写就没法测。
    public enum Action: Equatable {
        /// 书架出现（含从后台返回）。**幂等**：已在加载中就直接忽略
        case onAppear
        /// 拉取完成
        case loaded([ShelfRow])
        /// 拉取失败
        case loadFailed(String)

        /// 请求把某本书加入书架（搜索结果点「加入书架」时发）
        case addRequested(Book)
        /// 加入成功。带 `ShelfRow` 便于直接插进列表，不用重新拉全量
        case addSucceeded(ShelfRow)
        /// 加入失败（含「已在书架里」）
        case addFailed(String)
        /// 关闭提示横幅
        case noticeDismissed

        /// 分组列表拉取完成
        case groupsLoaded([ShelfGroupSnapshot])
        /// 选择分组；`nil` 表示「全部」
        case groupSelected(UUID?)
        /// 进入 / 退出编辑态
        case editModeChanged(Bool)
        /// 切换某本书的编辑选中状态
        case selectionToggled(String)
        /// 新建分组
        case createGroup(String)
        /// 新建分组成功
        case groupCreated(ShelfGroupSnapshot)
        /// 重命名分组
        case renameGroup(UUID, String)
        /// 重命名分组成功
        case groupRenamed(UUID, String)
        /// 删除分组
        case deleteGroup(UUID)
        /// 删除分组成功
        case groupDeleted(UUID)
        /// 把选中的书移入分组（`nil` = 未分组）
        case assignSelectedBooks(UUID?)
        /// 批量归类完成
        case booksGroupAssigned(UUID?)
        /// 删除选中的书
        case deleteSelectedBooks
        /// 删除完成，带回被删书的路径
        case booksDeleted([String])
        /// 为选中的书准备整本下载请求
        case downloadSelectedBooks
        /// 批量下载请求准备完成
        case batchDownloadPrepared([DownloadChapterRequest])
        /// 界面已把请求交给下载队列
        case batchDownloadConsumed
        /// 分组 / 批量操作失败
        case groupFailed(String)
        /// 关闭分组提示
        case groupNoticeDismissed
    }

    @Dependency(\.shelfLoader) var shelfLoader
    @Dependency(\.shelfAdder) var shelfAdder
    @Dependency(\.shelfGroupStore) var shelfGroupStore
    @Dependency(\.shelfBatchDownloader) var shelfBatchDownloader

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                return loadBookshelfAndGroups(loader: shelfLoader, groupStore: shelfGroupStore)

            case let .loaded(rows):
                state.rows = rows
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.errorMessage = message
                state.isLoading = false
                return .none

            case let .addRequested(book):
                state.addingCount += 1
                state.addNotice = nil
                return addToShelf(book: book, adder: shelfAdder)

            case let .addSucceeded(row):
                state.addingCount = max(0, state.addingCount - 1)
                // 🔴 去重后再插：并发加同一本时可能收到两次成功
                if !state.rows.contains(where: { $0.bookPath == row.bookPath }) {
                    state.rows.insert(row, at: 0)
                }
                // 重排：新书 `lastReadAt` 为 nil 应沉底，
                // 但用户刚加完就想看到它 —— 需求是「最近阅读倒序」，
                // 从未读过的按加入时间倒序，故直接插到最前符合语义。
                return .none

            case let .addFailed(message):
                state.addingCount = max(0, state.addingCount - 1)
                state.addNotice = message
                return .none

            case .noticeDismissed:
                state.addNotice = nil
                return .none

            case let .groupsLoaded(groups):
                state.groups = groups
                return .none

            case let .groupSelected(groupID):
                guard groupID != state.selectedGroupID else { return .none }
                state.selectedGroupID = groupID
                return .none

            case let .editModeChanged(isEditing):
                guard isEditing != state.isEditing else { return .none }
                state.isEditing = isEditing
                if !isEditing {
                    state.selectedBookPaths = []
                }
                return .none

            case let .selectionToggled(bookPath):
                if state.selectedBookPaths.contains(bookPath) {
                    state.selectedBookPaths.remove(bookPath)
                } else {
                    state.selectedBookPaths.insert(bookPath)
                }
                return .none

            case let .createGroup(name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.groupNotice = "分组名不能为空。"
                    return .none
                }
                state.groupNotice = nil
                return createGroup(named: trimmed, store: shelfGroupStore)

            case let .groupCreated(group):
                if !state.groups.contains(where: { $0.id == group.id }) {
                    state.groups.append(group)
                }
                state.groups.sort { $0.sortIndex < $1.sortIndex }
                state.selectedGroupID = group.id
                return .none

            case let .renameGroup(groupID, name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    state.groupNotice = "分组名不能为空。"
                    return .none
                }
                state.groupNotice = nil
                return renameGroup(groupID: groupID, name: trimmed, store: shelfGroupStore)

            case let .groupRenamed(groupID, name):
                if let index = state.groups.firstIndex(where: { $0.id == groupID }) {
                    state.groups[index] = ShelfGroupSnapshot(
                        id: groupID,
                        name: name,
                        sortIndex: state.groups[index].sortIndex
                    )
                }
                return .none

            case let .deleteGroup(groupID):
                state.groupNotice = nil
                return deleteGroup(groupID: groupID, store: shelfGroupStore)

            case let .groupDeleted(groupID):
                state.groups.removeAll { $0.id == groupID }
                if state.selectedGroupID == groupID {
                    state.selectedGroupID = nil
                }
                return .none

            case let .assignSelectedBooks(groupID):
                let paths = Array(state.selectedBookPaths)
                guard !paths.isEmpty else { return .none }
                state.groupNotice = nil
                return assignSelectedBooks(paths: paths, groupID: groupID, store: shelfGroupStore)

            case let .booksGroupAssigned(groupID):
                let selected = state.selectedBookPaths
                for index in state.rows.indices where selected.contains(state.rows[index].bookPath) {
                    state.rows[index].groupId = groupID
                }
                return .none

            case .deleteSelectedBooks:
                let paths = Array(state.selectedBookPaths)
                guard !paths.isEmpty else { return .none }
                state.groupNotice = nil
                return deleteSelectedBooks(paths: paths, store: shelfGroupStore)

            case let .booksDeleted(paths):
                let removed = Set(paths)
                state.rows.removeAll { removed.contains($0.bookPath) }
                state.selectedBookPaths.subtract(removed)
                if state.rows.isEmpty {
                    state.isEditing = false
                    state.selectedBookPaths = []
                }
                return .none

            case .downloadSelectedBooks:
                let paths = Array(state.selectedBookPaths)
                guard !paths.isEmpty else { return .none }
                state.groupNotice = nil
                return prepareBatchDownload(paths: paths, downloader: shelfBatchDownloader)

            case let .batchDownloadPrepared(requests):
                state.pendingDownloadRequests = requests
                return .none

            case .batchDownloadConsumed:
                state.pendingDownloadRequests = []
                return .none

            case let .groupFailed(message):
                state.groupNotice = message
                return .none

            case .groupNoticeDismissed:
                state.groupNotice = nil
                return .none
            }
        }
    }
}

// MARK: - 状态

/// 状态与 reducer body 分开声明，避免单个类型体量超过 SwiftLint 上限。
public extension BookshelfFeature {
    struct State: Equatable {
        public init(
            rows: [ShelfRow] = [],
            groups: [ShelfGroupSnapshot] = [],
            selectedGroupID: UUID? = nil,
            isLoading: Bool = false,
            errorMessage: String? = nil,
            addingCount: Int = 0,
            addNotice: String? = nil,
            isEditing: Bool = false,
            selectedBookPaths: Set<String> = [],
            groupNotice: String? = nil,
            pendingDownloadRequests: [DownloadChapterRequest] = []
        ) {
            self.rows = rows
            self.groups = groups
            self.selectedGroupID = selectedGroupID
            self.isLoading = isLoading
            self.errorMessage = errorMessage
            self.addingCount = addingCount
            self.addNotice = addNotice
            self.isEditing = isEditing
            self.selectedBookPaths = selectedBookPaths
            self.groupNotice = groupNotice
            self.pendingDownloadRequests = pendingDownloadRequests
        }

        /// 书架行，已按「最近阅读倒序」排好（排序在 `ShelfLoaderLive` 里做）
        public var rows: [ShelfRow] = []

        /// 用户创建的分组（不含隐含的「全部」）。
        public var groups: [ShelfGroupSnapshot] = []

        /// 当前选中的分组；`nil` 表示「全部」。
        public var selectedGroupID: UUID?

        /// 编辑态批量操作开关（长按或工具栏「选择」进入）。
        public var isEditing = false

        /// 编辑态选中的书（`bookPath` 集合）。
        public var selectedBookPaths: Set<String> = []

        /// 分组操作的提示横幅。
        public var groupNotice: String?

        /// 批量下载请求暂存，由界面交给下载队列后消费。
        public var pendingDownloadRequests: [DownloadChapterRequest] = []

        /// 首次加载中。用于区分「确实是空书架」与「还没加载完」
        public var isLoading = false

        /// 加载失败原因。
        /// 🔴 `rows` 为空**不等于**空书架 —— 必须结合本字段判断，
        /// 否则加载失败会被渲染成「书架空空如也」。
        public var errorMessage: String?

        /// 正在加入书架的书数（同时可能加多本）。
        /// 用计数而非布尔：并发加两本时，第一本完成不该把加载态清掉。
        public var addingCount = 0

        /// 加入书架失败/重复的提示（可关闭的横幅，不阻断列表）。
        /// 🔴 与 `errorMessage` 分开：那个是「整页加载失败」，这个是「某次操作失败」，
        /// 两者在界面上的呈现完全不同。
        public var addNotice: String?

        /// 当前分组下的行（「全部」= 不过滤）。
        public var visibleRows: [ShelfRow] {
            guard let selectedGroupID else { return rows }
            return rows.filter { $0.groupId == selectedGroupID }
        }
    }
}

// MARK: - Effect 辅助

/// 读取书架与分组。
///
/// 两组读操作先后各自独立失败：书架读失败只发 `loadFailed`，
/// 分组读失败只发 `groupFailed`，互不吞错。
private func loadBookshelfAndGroups(
    loader: ShelfLoader,
    groupStore: ShelfGroupStore
) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            let rows = try await loader.load()
            await send(.loaded(rows))
        } catch {
            await send(.loadFailed(String(describing: error)))
        }
        do {
            let groups = try await groupStore.loadGroups()
            await send(.groupsLoaded(groups))
        } catch {
            await send(.groupFailed(error.localizedDescription))
        }
    }
}

/// 把一本书加入书架。
private func addToShelf(book: Book, adder: ShelfAdder) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            let row = try await adder.add(book)
            await send(.addSucceeded(row))
        } catch {
            // 用 `localizedDescription` 而非 `String(describing:)`：
            // `ShelfAdderError` 实现了 `LocalizedError`，
            // 前者给出「《X》已经在书架里了」这种人话，
            // 后者会打印成 `alreadyExists(title: "X")` 这种代码腔。
            await send(.addFailed(error.localizedDescription))
        }
    }
}

/// 新建分组。
private func createGroup(
    named name: String,
    store: ShelfGroupStore
) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            let group = try await store.createGroup(name)
            await send(.groupCreated(group))
        } catch {
            await send(.groupFailed(error.localizedDescription))
        }
    }
}

/// 重命名分组。
private func renameGroup(
    groupID: UUID,
    name: String,
    store: ShelfGroupStore
) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            try await store.renameGroup(groupID, name)
            await send(.groupRenamed(groupID, name))
        } catch {
            await send(.groupFailed(error.localizedDescription))
        }
    }
}

/// 删除分组（书不删除，回到未分组）。
private func deleteGroup(
    groupID: UUID,
    store: ShelfGroupStore
) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            try await store.deleteGroup(groupID)
            await send(.groupDeleted(groupID))
        } catch {
            await send(.groupFailed(error.localizedDescription))
        }
    }
}

/// 批量归类：把选中的书移入分组（`nil` = 未分组）。
private func assignSelectedBooks(
    paths: [String],
    groupID: UUID?,
    store: ShelfGroupStore
) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            try await store.assignBooks(paths, groupID)
            await send(.booksGroupAssigned(groupID))
        } catch {
            await send(.groupFailed(error.localizedDescription))
        }
    }
}

/// 批量删除选中书。
private func deleteSelectedBooks(
    paths: [String],
    store: ShelfGroupStore
) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            try await store.removeBooks(paths)
            await send(.booksDeleted(paths))
        } catch {
            await send(.groupFailed(error.localizedDescription))
        }
    }
}

/// 把选中的书展开成整本下载请求。
private func prepareBatchDownload(
    paths: [String],
    downloader: ShelfBatchDownloader
) -> Effect<BookshelfFeature.Action> {
    .run { send in
        do {
            let requests = try await downloader.prepare(paths)
            await send(.batchDownloadPrepared(requests))
        } catch {
            await send(.groupFailed(error.localizedDescription))
        }
    }
}
