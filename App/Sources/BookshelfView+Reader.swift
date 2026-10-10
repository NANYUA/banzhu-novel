import ComposableArchitecture
import NovelCore
import SwiftUI

// 「单点书卡 ⇒ 直接进阅读页」这条链路的**视图侧装配**（owner 需求：书架 / 本地 / 分组
// 都不再进详情页，落点 = 上次看过的页面，从未看过 ⇒ 第一章第一页）。
//
// 为什么单独一个文件：`BookshelfView.swift` 已贴近 SwiftLint `file_length` 600 的硬门
// （CI 用 `--strict`，warning 即失败），而这条链路（准备态 / 失败提示 / push 目标 / 取目录）
// 是一块自成整体的新代码。拆法与 `BookshelfView+GroupBar.swift` 同一先例。
//
// ⚠️ 状态仍住在 `BookshelfView` 主类型里（跨文件 extension 不能加存储属性）：
// `readerTarget` / `readerBookTitle` / `isShowingReader` / `preparingBookPath` /
// `prepareErrorMessage` 与 `@Dependency(\.readingTargetLoader)` 都刻意**不是 `private`**，
// 本文件才读得到。

// MARK: - 打开阅读页

extension BookshelfView {
    /// 行上的进度快照 → `ReadingProgress`；从未读过 ⇒ `nil`（由依赖自己去读库）。
    ///
    /// 章名这里**只是把 `ReadingProgress` 填满**：落点的章名取自目录里的 `ChapterItem.name`
    /// （目录才是权威），所以 `lastReadChapterName` 缺失不影响定位。
    func progressHint(of row: ShelfRow) -> ReadingProgress? {
        guard let chapterPath = row.lastReadChapterPath else { return nil }
        return ReadingProgress(
            chapterPath: chapterPath,
            chapterName: row.lastReadChapterName ?? "",
            offset: row.lastReadOffset
        )
    }

    /// 单点书卡 → 直接进阅读页。
    ///
    /// `bookTitle` 由**入口那层**传进来（书架行 / 下载卡各自的模型字段），落进 `readerBookTitle`
    /// 供阅读页的角落标签用 —— 刻意**不**在这里按 `bookPath` 反查书库：下载页可能有不带书架行的
    /// 书，反查会静默拿到空标题。
    ///
    /// 取目录是**异步**的（`readingTargetLoader`），所以先置 `preparingBookPath` 进加载态
    /// （全页覆盖层，别让「点了没反应」），拿到落点再 push 阅读页；失败弹 alert（不静默）。
    func prepareReader(bookPath: String, bookTitle: String, progressHint: ReadingProgress? = nil) {
        // 防重入：正在准备时再点（同一本或另一本）一律忽略，避免两层覆盖 / 两次 push。
        guard preparingBookPath == nil else { return }
        preparingBookPath = bookPath
        readerBookTitle = bookTitle
        Task {
            await openReader(bookPath: bookPath, progressHint: progressHint)
        }
    }

    /// 取目录 + 定位落点，然后推入阅读页。`preparingBookPath` 无论成败都要复位。
    ///
    /// 显式 `@MainActor`：`Task {}` 会从**调用它的上下文**继承执行器，而这个方法在
    /// `await` 之后要写 `@State` —— 钉死在主线程上，不靠「按钮回调恰好在主线程」这个假设。
    @MainActor
    func openReader(bookPath: String, progressHint: ReadingProgress?) async {
        defer { preparingBookPath = nil }
        do {
            guard let target = try await readingTargetLoader.load(bookPath, progressHint) else {
                prepareErrorMessage = "这本书还没有目录，暂时打不开。联网打开一次目录后再试。"
                return
            }
            readerTarget = target
            isShowingReader = true
        } catch {
            prepareErrorMessage = "读取目录失败，请稍后重试。"
        }
    }

    /// 阅读页的 push 目标（`navigationDestination` 的 content）。
    @ViewBuilder
    var readerDestination: some View {
        if let target = readerTarget {
            ReaderView(
                chapterPath: target.chapterPath,
                chapterName: target.chapterName,
                bookPath: target.bookPath,
                bookTitle: readerBookTitle,
                chapters: target.chapters,
                downloadStore: downloadStore,
                initialOffset: target.initialOffset
            )
        }
    }
}

// MARK: - 准备态 / 失败提示

/// 取目录期间的反馈：**延迟出现的全页覆盖层** + 失败弹窗（不静默）。
///
/// 为什么要延迟：目录在本地已有快照时 `readingTargetLoader.load` 几十毫秒就返回，
/// 覆盖层一进加载态就渲染 ⇒ 只存在一帧就被撤掉，看起来就是「界面闪了一下」——
/// 闪一帧比「晚 150ms 才有反馈」更糟。延迟内加载已完成 ⇒ 覆盖层**从不渲染**。
/// 防重入**不靠**覆盖层挡点击，靠 `prepareReader` 里 `preparingBookPath == nil` 那道闸门。
private struct ReaderPreparationOverlay: ViewModifier {
    let isPreparing: Bool
    @Binding var failureMessage: String?

    /// 覆盖层出现前的等待时长：**观感取值**（150ms 落在常用区间，真机可调）。
    /// 放在本文件而不是 `DesignTokens` —— 那里只有 `Spacing` / `Radius`，没有时长段。
    private static let overlayDelay: Duration = .milliseconds(150)

    /// 出现时的淡入时长。极短：它只是「等得比预期久」的提示，不该自己变成一段动画。
    /// Reduce Motion 下**照旧保留**：纯透明度变化没有前庭刺激，降级 ≠ 无反馈。
    private static let overlayFadeDuration: TimeInterval = 0.13

    /// 覆盖层是否真的显示。与 `isPreparing` 分开：延迟就是这两个状态之间的差。
    @State private var showsOverlay = false

    func body(content: Content) -> some View {
        content
            // 用 `.regularMaterial` 而不是不透明底：内容仍透出来，用户知道自己在原地等。
            .overlay {
                if showsOverlay {
                    ZStack {
                        Rectangle().fill(.regularMaterial)
                        ProgressView("正在打开…")
                    }
                    .transition(.opacity)
                }
            }
            // `.task(id:)` 在 `isPreparing` 变化时会**自动取消**上一个任务：
            // · 快路径（延迟内就结束）⇒ 睡眠被取消 ⇒ `showsOverlay` 全程 `false`，覆盖层从不渲染；
            // · 回到 `false` 时在这里复位，下一次准备才能重新走延迟（不残留 `true` 一进去就闪）。
            // 刻意不用 `DispatchQueue.main.asyncAfter`：那不可取消，会留下「延迟到了才发现早就结束」的竞态。
            .task(id: isPreparing) {
                guard isPreparing else {
                    showsOverlay = false
                    return
                }
                try? await Task.sleep(for: Self.overlayDelay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: Self.overlayFadeDuration)) {
                    showsOverlay = true
                }
            }
            .alert(
                "打开失败",
                isPresented: Binding(
                    get: { failureMessage != nil },
                    set: {
                        if !$0 {
                            failureMessage = nil
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
    }
}

extension View {
    /// 挂上「准备进阅读页」的反馈（见 `ReaderPreparationOverlay`）。
    func readerPreparation(isPreparing: Bool, failureMessage: Binding<String?>) -> some View {
        modifier(ReaderPreparationOverlay(isPreparing: isPreparing, failureMessage: failureMessage))
    }
}

// MARK: - Preview

// 书架的预览放在这里，只为给主文件腾出 `file_length` 余量（预览与主文件同模块，行为无差别）。
#Preview {
    let store = Store(initialState: BookshelfFeature.State(
        rows: [
            ShelfRow(
                bookPath: "/49/49034/",
                title: "楚香君游戏",
                author: "某某某",
                coverUrl: "",
                lastReadChapterName: "第七章 夜探皇宫",
                latestChapterName: "第九章 风云起",
                unreadCount: 12,
                lastReadAt: Date()
            ),
            ShelfRow(
                bookPath: "/49/49035/",
                title: "另一本书",
                author: "",
                coverUrl: "",
                lastReadChapterName: nil,
                latestChapterName: "第一章",
                unreadCount: 0,
                lastReadAt: nil
            ),
        ],
        isLoading: false,
        errorMessage: nil
    )) {
        BookshelfFeature()
    }
    let downloadStore = Store(initialState: DownloadFeature.State()) {
        DownloadFeature()
    }
    BookshelfView(store: store, downloadStore: downloadStore)
}
