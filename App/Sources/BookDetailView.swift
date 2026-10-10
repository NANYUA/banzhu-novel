import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 书籍详情页。展示网站详情页字段，并作为进入阅读的唯一入口。
///
/// ## 目录就在本页（U1-6）
/// 外层是 `ScrollView`，**不能**把 `List` 塞进去（`List` 需要自己的滚动上下文，
/// 嵌进去高度会塌）。所以目录用 `LazyVStack` 渲染成普通内容，
/// 默认只渲染前 `BookDetailFeature.State.chapterPreviewLimit` 条，
/// 其余靠「查看全部目录」就地展开 —— 不再 push 单独的目录页。
///
/// ## 本站 / 原网站（U1-4）
/// 右上角「转到原网站」的 URL 由**用户当前配置的 host** + 本书 `bookPath` 现场拼出
/// （`BookDetailFeature.State.sourceURL`）；没配置 host 时这个入口整个不出现。
struct BookDetailView: View {
    let store: StoreOf<BookDetailFeature>
    let downloadStore: StoreOf<DownloadFeature>

    /// 加入书架成功后回调，供上层同步自己的列表（书架页 / 搜索页都可能是上层）。
    let onAddedToShelf: (ShelfRow) -> Void

    /// 移出书架成功后回调，供上层把这本书从列表里摘掉。
    let onRemovedFromShelf: (String) -> Void

    @State private var isIntroExpanded = false
    /// 简介「不被截断时的高度」与「4 行截断后的高度」，用来判断是否真的被截断（U1-5）。
    ///
    /// 初值 -1 = 「还没量到」；两个高度都量到之后才判决（见 `isIntroTruncated`）。
    @State private var introFullHeight: CGFloat = -1
    @State private var introClampedHeight: CGFloat = -1
    /// 要打开的那一章 + 显式 push 开关。
    ///
    /// 用 `Button` + 显式 push 而不是 `NavigationLink`：普通容器里的 `NavigationLink`
    /// 没有可感知的按下反馈，而本项目的硬约束是「按下必须有反馈」。
    @State private var readerChapter: ChapterItem?
    @State private var isShowingReader = false
    /// U1-7 的章节选择面板。
    @State private var isShowingChapterPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        book: Book,
        downloadStore: StoreOf<DownloadFeature>,
        onAddedToShelf: @escaping (ShelfRow) -> Void = { _ in },
        onRemovedFromShelf: @escaping (String) -> Void = { _ in }
    ) {
        self.downloadStore = downloadStore
        self.onAddedToShelf = onAddedToShelf
        self.onRemovedFromShelf = onRemovedFromShelf
        store = Store(initialState: BookDetailFeature.State(fallback: BookDetail(book: book))) {
            BookDetailFeature()
        }
    }

    init(
        bookPath: String,
        title: String,
        downloadStore: StoreOf<DownloadFeature>,
        onAddedToShelf: @escaping (ShelfRow) -> Void = { _ in },
        onRemovedFromShelf: @escaping (String) -> Void = { _ in }
    ) {
        self.downloadStore = downloadStore
        self.onAddedToShelf = onAddedToShelf
        self.onRemovedFromShelf = onRemovedFromShelf
        store = Store(
            initialState: BookDetailFeature.State(
                fallback: BookDetail(bookPath: bookPath, title: title)
            )
        ) {
            BookDetailFeature()
        }
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    header(viewStore.detail)
                    detailStatus(viewStore)
                    shelfSection(viewStore)
                    introSection(viewStore.detail.intro)
                    infoSection(viewStore.detail)
                    primaryActions(viewStore)
                    directorySection(viewStore)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
            // 与书架 / 搜索页统一：整页底色走 `systemGroupedBackground`，
            // 卡片（目录行、简介占位）压在它上面才有一级层次。
            .background(AppTheme.Surface.page)
            .navigationTitle("书籍详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { siteToolbarItem(viewStore) }
            .navigationDestination(isPresented: $isShowingReader) {
                readerDestination(viewStore)
            }
            .sheet(isPresented: $isShowingChapterPicker) {
                ChapterDownloadPicker(
                    chapters: viewStore.chapters,
                    // 计数从 reducer 的派生值单向下传：面板不再自己 filter().count，
                    // 目录 header 与面板 header 永远同一口径。
                    downloadedCount: viewStore.downloadedChapterCount,
                    downloadableCount: viewStore.downloadableChapterCount,
                    onConfirm: { selected in
                        isShowingChapterPicker = false
                        enqueue(
                            selected,
                            bookPath: viewStore.detail.bookPath,
                            bookTitle: viewStore.detail.title
                        )
                    }
                )
            }
            .task { viewStore.send(.onAppear) }
            // 下载进行中：观察下载队列的**纯内存**完成信号，把新增完成的章节就地标成已下载
            // （不重读目录 —— 500 章批量下载那样会退化成 O(n²)，见 `BookDetailView+DownloadRefresh`）。
            .background { downloadCompletionObserver(viewStore) }
            .onChange(of: viewStore.lastAddedRow) { _, row in
                if let row {
                    onAddedToShelf(row)
                }
            }
            .onChange(of: viewStore.lastRemovedPath) { _, bookPath in
                if let bookPath {
                    onRemovedFromShelf(bookPath)
                }
            }
        }
    }
}

// MARK: - 顶部 / 信息区

private extension BookDetailView {
    func header(_ detail: BookDetail) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            AsyncImage(url: URL(string: detail.coverUrl)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(Color(.tertiarySystemBackground))
                        .overlay {
                            Image(systemName: "book.closed")
                                .foregroundStyle(.quaternary)
                        }
                }
            }
            .frame(width: 92, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(detail.title.isEmpty ? "暂无书名" : detail.title)
                    .font(.title3.bold())
                    .lineLimit(2)

                Text(detail.author.isEmpty ? "未知作者" : detail.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !detail.status.isEmpty {
                    Text(detail.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }

                if !detail.category.isEmpty {
                    Text(detail.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func infoSection(_ detail: BookDetail) -> some View {
        VStack(spacing: 0) {
            DetailInfoRow(title: "字数", value: detail.wordCount)
            DetailInfoRow(title: "最新章节", value: detail.lastChapter)
            DetailInfoRow(title: "更新时间", value: detail.lastUpdated)
            DetailInfoRow(title: "标签", value: detail.tags.joined(separator: " · "), isLast: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .background(
            AppTheme.Surface.card,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        )
    }
}

// MARK: - 详情级状态（加载中 / 读取失败）

private extension BookDetailView {
    /// 详情级状态：**本地记录**（详情 + 是否在书架）与**未上架时的远端兜底**共用这一条展示槽。
    ///
    /// 两个失败分开记（`errorMessage` / `previewErrorMessage`：原因与重试目标都不同），
    /// 但同屏只可能有一个成立 —— 本地读不到记录才会去走远端兜底。
    ///
    /// 读库失败时页面只能继续显示搜索带来的回退字段，而 `isOnShelf` 会停在 false ——
    /// 已在书架的书看起来就像「没加入过」。所以失败必须说出来，并给一条重试。
    /// 这里的错误条与目录区块用的是同一个 `InlineErrorBanner`。
    @ViewBuilder
    func detailStatus(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        if viewStore.isLoading || viewStore.isPreviewLoading {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProgressView()

                Text(viewStore.isPreviewLoading ? "正在联网读取简介与目录…" : "正在读取本地记录…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let message = viewStore.errorMessage {
            InlineErrorBanner(
                title: "本地记录读取失败",
                message: message,
                onRetry: { viewStore.send(.reloadDetail) }
            )
        } else if let message = viewStore.previewErrorMessage {
            // 未上架的书：兜底失败时首屏只剩列表页回退字段（列表页没有简介）与空目录，
            // 连阅读按钮都不会出现 —— 必须给出原因与重试，不能安静地保持空白。
            InlineErrorBanner(
                title: "简介与目录读取失败",
                message: message,
                onRetry: { viewStore.send(.reloadPreview) }
            )
        }
    }
}

// MARK: - 加入 / 移出书架

private extension BookDetailView {
    /// 书架开关。按 `isOnShelf` 切换，两条分支都用 `controlSize(.large)` 拿到 44pt 触控目标。
    ///
    /// 视觉分工（§9 主次分明）：未加入时它是页面上一眼可见的**主按钮**；
    /// 已加入时退成次级按钮并把图标换成绿色 checkmark —— 状态一眼可辨，
    /// 文字仍写动作（§11：按钮标签用动词），避免「已加入」当按钮却看不出点了会怎样。
    func shelfSection(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if viewStore.isOnShelf {
                Button {
                    removeFromShelf(viewStore)
                } label: {
                    shelfLabel(viewStore, title: "移出书架", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.green)
            } else {
                Button {
                    viewStore.send(.addRequested)
                } label: {
                    shelfLabel(viewStore, title: "加入书架", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if let notice = viewStore.shelfNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.large)
        .disabled(viewStore.isShelfBusy)
    }

    @ViewBuilder
    func shelfLabel(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>,
        title: String,
        systemImage: String
    ) -> some View {
        if viewStore.isShelfBusy {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
    }

    func removeFromShelf(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) {
        // 与书架编辑态的删除保持一致：先把这本书在下载队列里的任务取消掉，
        // 再删本地记录与已下载正文。
        downloadStore.send(.cancelBook(viewStore.detail.bookPath))
        viewStore.send(.removeRequested)
    }
}

// MARK: - 简介（U1-5）

private extension BookDetailView {
    /// 简介是否**真的**被 4 行截断。
    ///
    /// 量文字行数没有公开 API，硬猜字数又不可靠，所以改为量高度：
    /// 一个隐藏的「不限行数」文本量出完整高度，和实际渲染的截断文本比 ——
    /// 完整高度更高才是被截断。只有那时才显示「展开」。
    ///
    /// ⚠️ 两个高度都量到（`> 0`）之前不下结论：两个 `GeometryReader` 的到达顺序不保证，
    /// 若只量到「完整高度」就先判，`0 < 完整高度` 会被当成截断，短简介会闪一下「展开」。
    var isIntroTruncated: Bool {
        introFullHeight > 0 && introClampedHeight > 0
            && introFullHeight > introClampedHeight + 0.5
    }

    func introSection(_ intro: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("简介")
                .font(.headline)

            if intro.isEmpty {
                introPlaceholder
            } else {
                Text(intro)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(isIntroExpanded ? nil : 4)
                    .background(heightReader($introClampedHeight))
                    .background(alignment: .top) {
                        // 只用于量高度：不参与显示、不接受点击，**也必须移出无障碍树** ——
                        // `.hidden()` 只让元素不可见，VoiceOver 仍会把整段简介再读一遍
                        // （第二遍还不在屏幕上，用户无从对应）。
                        Text(intro)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .background(heightReader($introFullHeight))
                    }

                if isIntroExpanded || isIntroTruncated {
                    Button {
                        toggleIntro()
                    } label: {
                        // §9：两轴都要 44pt —— 只给高度时「展开」只有约 24pt 宽。
                        Text(isIntroExpanded ? "收起" : "展开")
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 没有简介时的占位：给明确文案，而不是整块消失（页面塌出一截空白）。
    var introPlaceholder: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)

            Text("本书暂无简介")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.Surface.card,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        )
    }

    /// 把视图当前高度写回绑定（测高用；不参与布局）。
    func heightReader(_ height: Binding<CGFloat>) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { height.wrappedValue = proxy.size.height }
                .onChange(of: proxy.size.height) { _, newHeight in
                    height.wrappedValue = newHeight
                }
        }
    }

    func toggleIntro() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
            isIntroExpanded.toggle()
        }
    }
}

// MARK: - 阅读入口（U1-6）

private extension BookDetailView {
    /// 主行动入口：有上次阅读记录就是「继续阅读」（+「从第一章开始」），否则是「开始阅读」。
    ///
    /// 目录还没加载出来时**什么都不摆** —— 点了没反应的死按钮比没有按钮更糟，
    /// 而「加载中 / 失败 / 为空」由下面的目录区块统一表达（只在那里出一个 ProgressView，
    /// 首屏不会出现两条「目录加载中…」）。
    @ViewBuilder
    func primaryActions(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        if let continueChapter = viewStore.continueChapter {
            VStack(spacing: DesignTokens.Spacing.xs) {
                readButton(
                    "继续阅读",
                    systemImage: "book.pages",
                    chapter: continueChapter,
                    isProminent: true
                )
                if let first = viewStore.chapters.first, first.path != continueChapter.path {
                    readButton(
                        "从第一章开始",
                        systemImage: "text.book.closed",
                        chapter: first,
                        isProminent: false
                    )
                }
            }
        } else if let first = viewStore.chapters.first {
            readButton("开始阅读", systemImage: "book.pages", chapter: first, isProminent: true)
        }
    }

    @ViewBuilder
    func readButton(
        _ title: String,
        systemImage: String,
        chapter: ChapterItem,
        isProminent: Bool
    ) -> some View {
        if isProminent {
            Button {
                openReader(chapter)
            } label: {
                readLabel(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button {
                openReader(chapter)
            } label: {
                readLabel(title, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    func readLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    func openReader(_ chapter: ChapterItem) {
        // 防重入：连点两下时第一次已经 push 了阅读页，第二次不该再压一层。
        guard !isShowingReader else { return }
        readerChapter = chapter
        isShowingReader = true
    }
}

// MARK: - 目录与下载（U1-6 / U1-7）

private extension BookDetailView {
    /// 目录直接长在详情页里：数据是本地快照，由 reducer 自己加载。
    func directorySection(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        ChapterListView(
            data: ChapterDirectoryData(
                visibleChapters: viewStore.visibleChapters,
                totalCount: viewStore.chapters.count,
                downloadedCount: viewStore.downloadedChapterCount,
                hasHiddenChapters: viewStore.hasHiddenChapters,
                isShowingAll: viewStore.isShowingAllChapters,
                isLoading: viewStore.isLoadingChapters,
                errorMessage: viewStore.chapterErrorMessage
            ),
            onToggleShowAll: { viewStore.send(.toggleAllChapters) },
            onRetry: { viewStore.send(.reloadChapters) },
            onSelect: { chapter in openReader(chapter) },
            onDownloadChapter: { chapter in
                enqueue(
                    [chapter],
                    bookPath: viewStore.detail.bookPath,
                    bookTitle: viewStore.detail.title
                )
            },
            onDownloadRequested: presentChapterPicker
        )
    }

    /// 打开章节选择面板。防重入：面板已经在展示时不再重复置位
    /// （面板内容取自 `viewStore.chapters` 的当前值，不会拿到旧快照）。
    func presentChapterPicker() {
        guard !isShowingChapterPicker else { return }
        isShowingChapterPicker = true
    }

    /// 章节 → 下载队列。整本下载就是展开成 N 条按章请求（下载器一次只下一章）。
    func enqueue(_ chapters: [ChapterItem], bookPath: String, bookTitle: String) {
        guard !chapters.isEmpty else { return }
        downloadStore.send(.enqueue(chapters.map {
            DownloadChapterRequest(chapter: $0, bookPath: bookPath, bookTitle: bookTitle)
        }))
    }
}

// MARK: - 工具栏 / 导航（U1-4）

private extension BookDetailView {
    /// 右上角「转到原网站」。
    ///
    /// URL 由「用户当前配置的 host + 本书 bookPath」现场拼出（见 `State.sourceURL`），
    /// 页面上不出现任何写死的域名 / 路径特征；没配置 host 时 `sourceURL` 为 nil，
    /// 这里什么都不产出 —— 入口整体隐藏，而不是给一个点了没反应的按钮。
    @ToolbarContentBuilder
    func siteToolbarItem(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some ToolbarContent {
        if let url = viewStore.sourceURL {
            ToolbarItem(placement: .topBarTrailing) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("转到原网站")
            }
        }
    }

    @ViewBuilder
    func readerDestination(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        if let chapter = readerChapter {
            ReaderView(
                chapterPath: chapter.path,
                chapterName: chapter.name,
                bookPath: viewStore.detail.bookPath,
                chapters: viewStore.chapters,
                downloadStore: downloadStore
            )
        }
    }
}

// MARK: - 信息行

private struct DetailInfoRow: View {
    let title: String
    let value: String
    /// 末行不画分隔线：否则卡片底边上会多出一条像描边的线。
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .leading)

            Text(value.isEmpty ? "暂无" : value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider()
            }
        }
    }
}
