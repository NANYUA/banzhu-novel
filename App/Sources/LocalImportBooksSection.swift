import NovelCore

/// 把「本地导入的书」换算成书卡数据（`BookDownloadSummary`），让它们在「本地」页
/// 与下载进本地的那批书**用同一套书卡、同一种点击**。
///
/// ## 为什么需要这一层换算
/// 本地导入书没有 `DownloadTask`（导入时一次性落库落盘），而书卡的数据源是任务快照
/// ⇒ 不换算就进不了同一个 `List`。换算后：总章数 = 章节数、已完成 = 全部、
/// 状态恒 `.finished`（「已全部下载」）。
///
/// ## 为什么不再有独立段落
/// owner 2026-10-17 第三轮口径：「本地导入的书籍与其他下载的本地书籍应该完全相同，
/// 包括 UI 操作方式等，并且删除本地书籍下面的不需要联网提示」。
/// ⇒ 原先那个带 header「本地导入（n）」与 footer 小字的独立 `Section` 整段删除，
/// 这类书改由 `DownloadQueueView` 直接混进书卡列表。
///
/// ⚠️ 文件名沿用旧名（`LocalImportBooksSection.swift`）：提交里不允许出现重命名
/// （推送工具按路径取 blob，删/改名会让它取不到文件），所以只改内容、保留文件名。
func localBookSummaries(
    from books: [LocalBookRow],
    metas: [String: BookLibraryMeta] = [:]
) -> [BookDownloadSummary] {
    books.map { book in
        let meta = metas[book.bookPath]
        return BookDownloadSummary(
            id: book.bookPath,
            title: firstNonEmpty(meta?.title, book.title),
            author: firstNonEmpty(meta?.author, book.author),
            coverUrl: firstNonEmpty(meta?.coverUrl),
            chapterCount: book.chapterCount,
            finishedCount: book.chapterCount,
            status: .finished
        )
    }
}
