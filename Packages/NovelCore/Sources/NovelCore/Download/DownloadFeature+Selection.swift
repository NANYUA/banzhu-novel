import ComposableArchitecture

/// 书卡选择模式的状态逻辑（U10）。
///
/// ## 为什么单独一个文件
/// `DownloadFeature.swift` 已贴着 SwiftLint `file_length` 的 warning 线（600，CI `--strict`
/// 下即失败），所以本轮新增的状态逻辑一律放这里；`State` 的**存储属性**声明仍在
/// `DownloadFeature+State.swift`（Swift 不允许在 extension 里加存储属性）。
///
/// ## 选择模式的判据
/// 勾选的单位是**书**（`bookPath`），不是章节：队列里一本书可能有很多条章节任务，
/// 而本地页现在一本书只有一张书卡。所以「全选」= 选中当前队列里的**全部书**。
/// 书目顺序只有 `bookPaths` 一处定义，书卡分组也从它取顺序。
extension DownloadFeature.State {
    /// 队列里出现的书（按入队顺序去重）。
    ///
    /// 选择模式的「全选」判据与书卡分组**共用这一处**。
    public var bookPaths: [String] {
        var seen: Set<String> = []
        return tasks.map(\.bookPath).filter { seen.insert($0).inserted }
    }

    /// 队列里的书是否已被全选（空队列恒为 `false`）。
    public var areAllBooksSelected: Bool {
        let all = Set(bookPaths)
        return !all.isEmpty && selectedBookPaths == all
    }

    /// 选中书里还有排队 / 进行中的任务（批量「暂停下载」是否可用）。
    public var canPauseSelectedBooks: Bool {
        tasks.contains { selectedBookPaths.contains($0.bookPath) && $0.state.isActive }
    }

    /// 选中书里还有失败的任务（批量「重试失败」是否可用）。
    public var canRetryFailedSelectedBooks: Bool {
        tasks.contains { selectedBookPaths.contains($0.bookPath) && $0.state == .failed }
    }

    /// 进入 / 退出选择模式。退出时清空选择（与书架「完成」同一语义）。
    mutating func applySelectionMode(_ isSelecting: Bool) {
        self.isSelecting = isSelecting
        if !isSelecting {
            selectedBookPaths.removeAll()
        }
    }

    /// 勾选 / 取消一本书。
    mutating func toggleBookSelection(_ bookPath: String) {
        if selectedBookPaths.contains(bookPath) {
            selectedBookPaths.remove(bookPath)
        } else {
            selectedBookPaths.insert(bookPath)
        }
    }

    /// 全选 / 取消全选队列里的书。
    mutating func toggleSelectAllBooks() {
        let all = Set(bookPaths)
        selectedBookPaths = selectedBookPaths == all ? [] : all
    }

    /// 把已不在队列里的书从选择里剔除。
    ///
    /// 只在队列重载时调用；**不**在这里退出选择模式 —— 用户刚长按进入选择模式时
    /// 选择本来就是空的，一退出就变成「长按没反应」。
    mutating func pruneSelection() {
        selectedBookPaths.formIntersection(bookPaths)
    }
}

/// 「删除下载」：取消这本书的下载任务 **+ 删掉它已下载的正文**，但**保留书架上的书**。
///
/// ## 与 `.cancelBook` 的分工
/// - `.cancelBook`：书架「移出书架 / 批量删书」的配套动作，只清队列（书目由书架那边删）；
/// - 本函数：本地页「删除下载」，清队列 **且**删正文，**不动书目** —— 用户随时能重新下载。
///
/// ## 删正文复用哪条既有路径
/// `DownloadQueueStore.removeDownloadedChapters(bookPaths:)`（与 `complete(taskID:text:)`
/// 互为逆操作：删文件 + 把 `ChapterRecord.source` 复位成 `.notDownloaded`，
/// 复位会同时清掉 `localFileName` / `savedAt`）。
/// 🔴 **不走** `CacheEvictionPlanner` / `evictCachedChapters`：那条是 LRU 淘汰，
/// 候选集只含 `.cached`（契约②：用户下载的章节永不被淘汰），拿来删 `.downloaded`
/// 既删不掉、语义也不对。这里是**用户主动删除**。
func deleteBookDownloads(
    _ bookPaths: [String],
    state: inout DownloadFeature.State,
    queue: DownloadQueueStore
) -> Effect<DownloadFeature.Action> {
    let targets = Set(bookPaths)
    guard !targets.isEmpty else { return .none }

    let affected = state.tasks.filter { targets.contains($0.bookPath) }
    let ids = affected.map(\.id)
    if targets.count == 1 {
        state.notice = "已删除《\(affected.first?.bookTitle ?? "该书")》的下载，已下载的正文已清除。"
    } else {
        state.notice = "已删除选中的 \(targets.count) 本书的下载，已下载的正文已清除。"
    }

    // 本地先移除：正在飞的那一项结果回来时找不到任务，会被当作作废结果丢弃
    // （与 `.cancelBook` 同一手法；**不清 `isDownloading`** —— 旧请求可能还没结束）。
    state.tasks.removeAll { targets.contains($0.bookPath) }

    // 删掉的书立刻退出选择：批量删完还留在选择模式里，会让人以为「还没删」。
    state.selectedBookPaths.subtract(targets)
    if state.selectedBookPaths.isEmpty {
        state.isSelecting = false
    }

    let store = queue
    return .run { send in
        do {
            // 顺序：先删正文并复位 `ChapterRecord`，再删队列里的任务。
            // 反过来先删任务的话，中途失败会留下「正文还在、队列里已看不见」的孤儿正文。
            try await store.removeDownloadedChapters(bookPaths)
            try await store.remove(ids)
            await send(.reload)
        } catch {
            await send(.storeFailed(error.localizedDescription))
        }
    }
}
