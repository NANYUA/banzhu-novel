import ComposableArchitecture
import Dependencies
import NovelCore
import SwiftUI

/// 阅读页「下载」面板的入参：阅读页手里那份状态原样带过来。
///
/// ## 为什么收成一个值类型
/// 面板要的是一整组「书 + 当前章 + 预缓存章数 + 目录快照 + 下载队列 store」。
/// 逐个当参数传会越过 SwiftLint `function_parameter_count` 的 warning 5
/// （CI `--strict` 下 warning 即失败；先例是 `ReaderPageJump`）。
struct ReaderDownloadPickerInput {
    /// 书路径（入队用）。
    let bookPath: String
    /// 书名（入队用）。**必须是阅读页的真书名** —— 传空串会让下载队列里的书卡没有名字。
    let bookTitle: String
    /// 阅读页此刻在读的章节路径（默认勾选的中心）。
    let currentChapterPath: String
    /// 阅读页此刻在读的章节名（路径对不上新目录时的兜底匹配键）。
    let currentChapterName: String
    /// 阅读设置里的预缓存章数（`ReaderFeature.State.precacheCount`，既有 clamp 0…20）。
    /// 口径：「默认勾选的后续几章」就是它 —— 它的既有语义正是「自动预缓存后续几章」。
    let precacheCount: Int
    /// 阅读页手里的目录快照（`ReadingTarget.chapters`，**打开阅读页那一刻**的那份）。
    /// 只作刷新失败时的回退与刷新期间的兜底，不当最新目录用。
    let snapshotChapters: [ChapterItem]
    /// 下载队列 store；`nil` = `init(store:)` 那条测试 / 预览路径（那条路径不打开本面板）。
    let downloadStore: StoreOf<DownloadFeature>?
}

extension ReaderView {
    /// 「下载」按钮弹出的章节选择面板。
    ///
    /// 面板本体是**详情页同一个** `ChapterDownloadPicker`（不另造第二个选择界面），
    /// 差异只有两处：打开时按「当前章 + 后续预缓存章数」预选；目录是**每次打开现取**的。
    ///
    /// 单表达式返回 ⇒ 不写 `@ViewBuilder`（SwiftFormat 的 `redundantViewBuilder` 会报）。
    func downloadPickerSheet(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        ReaderDownloadPickerSheet(
            input: ReaderDownloadPickerInput(
                bookPath: bookPath,
                bookTitle: bookTitle,
                currentChapterPath: viewStore.chapterPath,
                currentChapterName: viewStore.chapterName,
                precacheCount: viewStore.precacheCount,
                snapshotChapters: chapters,
                downloadStore: downloadStore
            )
        )
    }
}

/// 阅读页的章节选择面板：**打开时**取一次最新目录，再交给 `ChapterDownloadPicker` 渲染。
///
/// ## 为什么要现取
/// 阅读页手里的 `chapters` 是**打开阅读页那一刻的快照**（`ReadingTarget.chapters`），
/// 刚下载完的章在它眼里仍然是「未下载」⇒ 再打开面板还能重复勾选、也看不到「已下载」。
/// 所以面板每次打开都用目录依赖重新读一遍，`isDownloaded` 才是此刻的真值。
///
/// ## 为什么用 `readingTargetLoader` 而不是 `chapterListLoader`
/// `chapterListLoader` 是 NovelCore 的**模块内**依赖（App 拿不到，见 `ReadingTargetLoader`
/// 的类型注释），而 `readingTargetLoader` 是它唯一的公开出口 —— 内部就是同一句
/// `chapterListLoader.load(bookPath)`（同一份快照、同一套按章号升序）⇒ 口径不分叉，
/// 也不必为了读目录去改 NovelCore 的可见性。
/// 传 `nil` 进度提示：返回的落点本面板不用，只取它的 `chapters`（代价是多一次本地的进度读）。
///
/// ## 刷新期间显示什么
/// 显示「正在获取最新目录…」+ 取消按钮，**不**先把旧快照摆上来：旧快照里的「已下载」是过期的，
/// 摆上去等于让用户对着**错的**状态勾选 —— 那正是本次要修的病。目录是本地 SwiftData 读，
/// 通常一闪而过；中间态同时给一条退出路径，面板不会显得卡住（下滑关闭同样可用）。
///
/// ## 失败怎么降级
/// 取最新目录抛错（或这本书已没有目录快照）⇒ 退回阅读页手里那份快照渲染。
/// 阅读页的既有风格是**安静降级**：不弹错误框打断阅读。代价是这一次的「已下载」标记可能偏旧，
/// 但面板仍然可用（计数与勾选都按传进 `ChapterDownloadPicker` 的那个数组自洽）。
///
/// ## ⚠️ 边界：不回写 `ReaderView.chapters`
/// 刷新到的目录**只用于本面板渲染**。`ReaderView.chapters` 是阅读导航的数据源
/// （章尾无缝换章 / 跳章条 / 目录 sheet 都吃它，来自 `ReadingTarget`），换掉它属于另一个面。
private struct ReaderDownloadPickerSheet: View {
    let input: ReaderDownloadPickerInput

    @Dependency(\.readingTargetLoader) private var readingTargetLoader
    /// 面板要渲染的目录；`nil` = 还在取最新目录（中间态）。
    @State private var chapters: [ChapterItem]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let chapters {
                picker(chapters)
            } else {
                loadingView
            }
        }
        .task { await refreshChapters() }
    }
}

private extension ReaderDownloadPickerSheet {
    /// 刷新中的中间态：明说在做什么，并给一条退出路径。
    var loadingView: some View {
        NavigationStack {
            ProgressView("正在获取最新目录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("选择章节")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") {
                            dismiss()
                        }
                    }
                }
        }
    }

    func picker(_ chapters: [ChapterItem]) -> some View {
        ChapterDownloadPicker(
            chapters: chapters,
            downloadedCount: downloadedCount(in: chapters),
            downloadableCount: chapters.count - downloadedCount(in: chapters),
            preselected: preselection(in: chapters),
            onConfirm: { selected in
                enqueue(selected)
            }
        )
    }

    /// 面板 header 的「已下载」计数：按**同一个** `chapters` 数组现算。
    ///
    /// 详情页那边这两个计数来自 `BookDetailFeature.State` 的派生值（目录 header 与面板 header
    /// 必须同一口径）。阅读页**没有**对应的派生值，而这里的数据源就是喂给面板的同一个数组
    /// ⇒ 现算不会与面板看到的内容分叉（面板的「全选」也读同一个数组）。
    func downloadedCount(in chapters: [ChapterItem]) -> Int {
        chapters.filter(\.isDownloaded).count
    }

    /// 默认勾选：**当前章 + 其后 `precacheCount` 章**（按目录顺序，`chapters` 是有序的）。
    ///
    /// 三个边界：
    /// - **当前章是最后一章**：窗口自然只剩它自己（`prefix` 越界不报错）；
    /// - **当前章不在刷新后的目录里**（目录被重建过 / 章节被删）：先按章节名兜底匹配，
    ///   仍匹配不上就**不预选** —— 宁可空手让用户自己挑，也不把别的章当成本章勾上；
    /// - **`precacheCount` 为 0**：只勾当前章（与「0 表示只缓存当前章」的既有语义一致）。
    ///
    /// 已下载的章**不在这里剔**：`ChapterDownloadPicker` 的预选逐章走
    /// `ChapterDownloadSelection.toggle(_:)`，而它本来就拒绝已下载的章
    /// ⇒ 预选与用户手点共用同一条路径，不会出现「勾了一个不可勾的项」。
    func preselection(in chapters: [ChapterItem]) -> [ChapterItem] {
        guard let index = currentChapterIndex(in: chapters) else { return [] }
        return Array(chapters[index...].prefix(input.precacheCount + 1))
    }

    /// 定位「当前正在读的这一章」：先按路径，再按章节名兜底。
    func currentChapterIndex(in chapters: [ChapterItem]) -> Int? {
        if let index = chapters.firstIndex(where: { $0.path == input.currentChapterPath }) {
            return index
        }
        return chapters.firstIndex(where: { $0.name == input.currentChapterName })
    }

    /// 确认：把勾选的章入队，然后关掉面板（与详情页「确认后关面板」一致）。
    ///
    /// `bookTitle` 传阅读页的真书名，绝不传空串 —— 空书名会让下载队列 / 本地页的书卡没有名字。
    func enqueue(_ selected: [ChapterItem]) {
        if let downloadStore = input.downloadStore {
            downloadStore.send(.enqueue(selected.map {
                DownloadChapterRequest(
                    bookPath: input.bookPath,
                    bookTitle: input.bookTitle,
                    chapterPath: $0.path,
                    chapterName: $0.name,
                    chapterNumber: $0.number
                )
            }))
        }
        dismiss()
    }

    /// 取最新目录：成功就用它；抛错或这本书已没有目录快照 ⇒ 退回阅读页手里的快照。
    func refreshChapters() async {
        do {
            let target = try await readingTargetLoader.load(input.bookPath, nil)
            chapters = target?.chapters ?? input.snapshotChapters
        } catch {
            chapters = input.snapshotChapters
        }
    }
}
