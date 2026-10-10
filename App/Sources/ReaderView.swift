import ComposableArchitecture
import NovelCore
import NovelPagination
import SwiftUI
import UIKit

/// 阅读页 —— 显示一章正文，支持滑动 / 点击 / 滚动三种翻页方式。
///
/// ## 渲染方案（docs/04 路线 C 的「单 UITextView」变体）
/// 分页模式用单个 `UITextView` 显示当前页；滚动模式用同一个
/// `UITextView` 显示整章并监听滚动位置。
/// 平移翻页（`pageTurnMode == .slide`，U9-4）改为铺「当前页 + 相邻页」一起平移，
/// 手势与全景图都在 `ReaderView+PageGesture.swift`。
///
/// ## 数据流
/// `currentOffset`（字符偏移，不是页码）→ reducer 反查所在页 → View 取
/// `pages[pageIndex]` 的字符范围渲染。滚动模式则把滚动位置换算成字符偏移
/// 回写给 reducer，切换设置后仍能靠 offset 定位。
///
/// ## 分页度量注入
/// 创建 store 时用 `withDependencies` 注入真实 `TextKitMeasuring`（NovelPagination），
/// 替换 NovelCore 里的 Fake 占位 —— 这样真机上分页才是真实排版。
struct ReaderView: View {
    let store: StoreOf<ReaderFeature>
    let bookPath: String
    let chapters: [ChapterItem]
    let downloadStore: StoreOf<DownloadFeature>?

    @State private var isShowingSettings = false
    @State private var isShowingDirectory = false
    @State private var isShowingSearch = false
    @State private var isChromeVisible = false
    // 下面四个是滑动 / 平移的跟手状态。**刻意不加 `private`**：Swift 的 `private` 是本文件级的，
    // 而手势已搬到 `ReaderView+PageGesture.swift`，加 `private` 那边就取不到
    // （与 `ReaderView+PageTurn.swift` 放开 `reduceMotion` 同一处理）。
    @State var slideOffset: CGFloat = 0
    @State var slideIsHorizontal: Bool?
    /// 本次手势的抓取基线（第一次 `onChanged` 采一次，抬手即复位）。
    @State var slideBaseline: CGFloat?
    /// 页面**此刻真实显示**的偏移（由探针每帧回报的呈现值，方案 A 的基线来源）。
    @State var slidePresentation = SlidePresentation()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 便捷构造：给定章节路径，创建带真实排版度量的阅读页 store。
    init(
        chapterPath: String,
        chapterName: String = "",
        bookPath: String = "",
        chapters: [ChapterItem] = [],
        downloadStore: StoreOf<DownloadFeature>? = nil
    ) {
        self.bookPath = bookPath
        self.chapters = chapters
        self.downloadStore = downloadStore
        store = Store(
            initialState: ReaderFeature.State(
                chapterPath: chapterPath,
                chapterName: chapterName
            )
        ) {
            ReaderFeature()
        } withDependencies: {
            // 注入真实排版度量（UIKit 实现，NovelCore 里的是 Fake 占位）
            $0.paginationService.paginate = { text, config in
                Paginator(measurer: TextKitMeasuring()).paginate(text: text, configuration: config)
            }
        }
    }

    /// 测试/嵌入用：直接接收外部 store（含 preview 等场景）。
    init(store: StoreOf<ReaderFeature>) {
        self.store = store
        bookPath = ""
        chapters = []
        downloadStore = nil
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            GeometryReader { geometry in
                let contentSize = readerContentSize(
                    size: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets
                )
                ZStack {
                    backgroundColor(for: viewStore.config)
                        .ignoresSafeArea()

                    // 正文与上下栏共用同一个「安全区可用盒」：两栏不再按全屏坐标钉边，
                    // 避免顶栏压灵动岛、底栏压 Home Indicator（B0-4）。
                    ZStack {
                        readerContent(
                            viewStore,
                            availableWidth: contentSize.width,
                            availableHeight: contentSize.height
                        )

                        if isChromeVisible {
                            readerChrome(viewStore)
                                .transition(.opacity)
                        }
                    }
                    .padding(.leading, geometry.safeAreaInsets.leading)
                    .padding(.trailing, geometry.safeAreaInsets.trailing)
                    .padding(.top, geometry.safeAreaInsets.top)
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                }
                .task {
                    viewStore.send(.loadSavedSettings(contentSize))
                    viewStore.send(
                        .loadChapterWithName(viewStore.chapterPath, viewStore.chapterName)
                    )
                }
                // 监听「安全区可用盒」而不是 `geometry.size`：翻转 / 分屏 / 换机型改的是 `size`，
                // 而通话或录屏状态栏、外接键盘导致的 Home Indicator 变化**只改 `safeAreaInsets`**
                // —— 后者原先漏监听，安全区变了却不重新分页（H2）。
                // 两者都会改变 `contentSize`，所以统一派生值触发即可，不必挂两个 onChange。
                // 藏掉状态栏（U9-3b）同样会改 `contentSize`，也走这条路径重新分页。
                .onChange(of: contentSize) { _, newSize in
                    viewStore.send(.containerSizeChanged(newSize))
                }
            }
            .navigationTitle("")
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            // 正文全屏（U9-3b）：连状态栏一起藏掉 —— 正文的上边界因此就是灵动岛 / 刘海下沿。
            // 底栏（tabBar）**刻意不在这里声明**：它的可见性全仓只有三个 tab 根视图一个所有者，
            // 由 `isShowingDetail` 驱动（U3-5）。阅读页只能从详情页进入，那一刻它已经是隐藏的；
            // 在这里再写一次 `.toolbar(.hidden, for: .tabBar)` 就会多出第二个所有者，
            // 正是 U3-5 修掉的「pop 回根视图后底栏不恢复」那种泄漏。
            .statusBar(hidden: true)
            .sheet(isPresented: $isShowingSettings) {
                ReaderSettingsView(
                    configuration: viewStore.config,
                    precacheCount: viewStore.precacheCount,
                    onPrecacheCountChange: { newCount in
                        viewStore.send(.precacheCountChanged(newCount))
                    },
                    onChange: { newConfiguration in
                        viewStore.send(.configChanged(newConfiguration))
                    }
                )
            }
            .sheet(isPresented: $isShowingDirectory) {
                directorySheet(viewStore)
            }
            .sheet(isPresented: $isShowingSearch) {
                ReaderSearchView(
                    bookPath: bookPath,
                    onSelect: { chapter in
                        viewStore.send(
                            .loadChapterWithName(chapter.chapterPath, chapter.chapterName)
                        )
                        isShowingSearch = false
                    }
                )
            }
            .preferredColorScheme(viewStore.config.appearanceMode.preferredColorScheme)
        }
    }
}

private extension ReaderView {
    // MARK: - 内容

    /// 阅读正文可用的安全区尺寸（全屏减去状态栏 / 灵动岛 / Home Indicator）。
    ///
    /// 这就是 U9-3b 说的「正文显示区域 = 贴安全区」：上边到灵动岛 / 刘海下沿、
    /// 下边到 Home Indicator 上沿；左右两侧另由 `PageInset` 的左右边距设置负责。
    /// **上下不再额外加留白** —— `PageInset` 的上下默认值已改为 0（U9-3b）。
    private func readerContentSize(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGSize {
        CGSize(
            width: max(0, size.width - safeAreaInsets.leading - safeAreaInsets.trailing),
            height: max(0, size.height - safeAreaInsets.top - safeAreaInsets.bottom)
        )
    }

    @ViewBuilder
    private func readerContent(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        availableHeight _: CGFloat
    ) -> some View {
        if viewStore.isLoading, viewStore.text.isEmpty {
            ProgressView("加载中…")
        } else if let message = viewStore.errorMessage, viewStore.text.isEmpty {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") {
                    viewStore.send(.loadChapter(viewStore.chapterPath))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            pageContent(viewStore, availableWidth: availableWidth)
        }
    }

    private func pageContent(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) -> some View {
        let configuration = viewStore.config
        // 平移翻页（U9-4）：全景图铺「当前页 + 相邻页」一起平移。
        // 「什么时候算平移翻页」的判据只有一处 —— `usesPanTurning`。
        let usesPan = usesPanTurning(viewStore)
        let page = ZStack {
            if usesPan {
                panPages(viewStore, availableWidth: availableWidth)
            } else {
                singlePage(viewStore, configuration: configuration)
            }
        }
        .contentShape(Rectangle())
        // 平移翻页本身就是转场，不再叠一层换页动画（叠了就是两个动画互相打架）。
        .animation(
            usesPan || configuration.pageTurnMode == .scroll
                ? nil
                : pageAnimation(for: configuration.pageTurnAnimation),
            value: viewStore.currentPageIndex
        )

        return readerGesture(
            page,
            viewStore: viewStore,
            availableWidth: availableWidth,
            onCenterTap: {
                setChromeVisible(!isChromeVisible)
            }
        )
    }

    /// 单页渲染：点击 / 滚动方式用，平移不可用（Reduce Motion、未分页）时也用它兜底。
    private func singlePage(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        configuration: PaginationConfiguration
    ) -> some View {
        let displayText = configuration.pageTurnMode == .scroll
            ? viewStore.text
            : currentPageText(viewStore)

        return PageTextView(
            text: displayText,
            offset: viewStore.currentOffset,
            configuration: configuration,
            onOffsetChange: { offset in
                viewStore.send(.jumpToOffset(offset))
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(configuration.pageTurnMode == .scroll)
        .id(pageIdentity(viewStore))
        .transition(
            pageTransition(
                for: configuration.pageTurnAnimation,
                direction: viewStore.pageTurnDirection
            )
        )
    }

    // MARK: - 控制栏

    private func readerChrome(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        VStack {
            readerTopBar(viewStore)

            Spacer()

            readerBottomBar(viewStore)
        }
    }

    /// 上栏。
    ///
    /// 位置（U9-5）：整条 `readerChrome` 已经在「安全区可用盒」里（body 的四条
    /// `.padding(…safeAreaInsets…)`），所以**不再额外加顶部内边距**，上栏的上边缘
    /// 正好落在正文区域的上边界 —— 也就是屏幕左上 / 右上圆角弧度开始处，
    /// 而不是贴在状态栏上（状态栏已由 `.statusBar(hidden: true)` 藏掉）。
    /// 圆角半径本身**不猜**：不同机型一律由安全区自适应。
    private func readerTopBar(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("返回", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            // HIG §9：`.bordered` 默认约 34pt 高。阅读页控制栏是阅读区内唯一的导航 /
            // 关闭入口，命中区按 44pt 补足（控制栏高度 +10pt，视觉语言不变）。
            .controlSize(.large)

            Spacer()

            Text(viewStore.chapterName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer()

            readerMoreMenu()
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(.systemBackground))
                : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
        )
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    /// 右上角「更多」菜单（U9-6）。
    ///
    /// 只把原来的 `eye.slash`（隐藏控制栏）换成 `ellipsis.circle` —— 控制栏显隐能力本身
    /// **没有丢**：中央点击那条路径仍在（`pageContent` 的 `onCenterTap`），
    /// 下载完成后自动隐藏也仍在，两条都还走 `setChromeVisible` 这一个写入口（U1-2）。
    /// 被去掉的只有 `eye.slash` 这一个**入口**，那是 owner 明确要求的替换。
    ///
    /// ⚠️ **更多选项待添加**：先放一条不可点的占位项，而不是留一个空 `Menu`
    /// —— 空菜单点开是一片空白，用户会以为控件坏了（§11 反馈：别给一个点了没反应的入口）。
    private func readerMoreMenu() -> some View {
        Menu {
            Button("更多选项待添加") {}
                .disabled(true)
        } label: {
            Image(systemName: "ellipsis.circle")
                // HIG §9：视觉图标可小于 44pt，命中区必须补足。
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityLabel("更多")
    }

    /// 下栏。
    ///
    /// 位置（U9-5）与上栏同理：**不再额外加底部内边距**，下栏的下边缘正好落在正文区域的
    /// 下边界 —— 也就是屏幕左下 / 右下圆角弧度开始处，而不是贴在 Home Indicator 上。
    private func readerBottomBar(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        HStack(spacing: 0) {
            chromeButton("目录", systemImage: "list.bullet") {
                isShowingDirectory = true
            }
            chromeButton("下载", systemImage: "arrow.down.circle") {
                downloadCurrentChapter(viewStore)
            }
            chromeButton("搜索", systemImage: "magnifyingglass") {
                isShowingSearch = true
            }
            chromeButton("设置", systemImage: "textformat.size") {
                isShowingSettings = true
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(.systemBackground))
                : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
        )
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    private func chromeButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        // §9 按下反馈：`.plain` 按下零反馈。强调层贴按钮自身的 12pt 圆角矩形，
        // 不再与外面这根 18pt 圆角的材质条在圆角处打架。
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))))
        .foregroundStyle(.primary)
    }

    private func directorySheet(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        NavigationStack {
            List(chapters) { chapter in
                Button {
                    viewStore.send(.loadChapterWithName(chapter.path, chapter.name))
                    isShowingDirectory = false
                } label: {
                    HStack {
                        Text(chapter.name)
                            .lineLimit(1)
                        Spacer()
                        if chapter.path == viewStore.chapterPath {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("目录")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        isShowingDirectory = false
                    }
                }
            }
        }
    }

    private func downloadCurrentChapter(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) {
        guard let downloadStore,
              let chapter = chapters.first(where: { $0.path == viewStore.chapterPath })
        else {
            return
        }
        downloadStore.send(.enqueue([
            DownloadChapterRequest(
                bookPath: bookPath,
                bookTitle: "",
                chapterPath: chapter.path,
                chapterName: chapter.name,
                chapterNumber: chapter.number
            ),
        ]))
        setChromeVisible(false)
    }

    // MARK: - 控制栏显隐

    /// 控制栏显隐的**唯一**写入口（U1-2）。
    ///
    /// 上栏（`readerTopBar`）与下栏（`readerBottomBar`）都包在 `readerChrome` 里，
    /// 由 body 里同一个 `if isChromeVisible` 与同一个 `.transition(.opacity)` 控制：
    /// 两者在物理上无法分别隐藏，所以显隐的**时机与动画也必须只有一处决定**。
    /// 中央点击 / 下载后自动隐藏全部走这里（U9-6 之后 `eye.slash` 那条入口已按 owner
    /// 要求换成「更多」菜单，见 `readerMoreMenu`），杜绝再次分叉。
    private func setChromeVisible(_ visible: Bool) {
        guard isChromeVisible != visible else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
            isChromeVisible = visible
        }
    }

    // MARK: - 外观

    private func backgroundColor(for configuration: PaginationConfiguration) -> Color {
        Color(uiColor: configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor
        ))
    }

    private func pageIdentity(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        guard viewStore.config.pageTurnMode != .scroll else { return "scroll" }
        return "page-\(viewStore.currentPageIndex)"
    }

    // MARK: - 分页定位

    /// 取当前页对应的文本片段。
    private func currentPageText(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        let pages = viewStore.pages
        let offset = viewStore.currentOffset
        let text = viewStore.displayText

        guard !pages.isEmpty, !text.isEmpty else { return text }
        guard let page = pages.first(where: { offset >= $0.location && offset < $0.location + $0.length }) else {
            return text
        }
        let chars = Array(text)
        let start = min(page.location, chars.count)
        let end = min(page.location + page.length, chars.count)
        guard start < end else { return "" }
        return String(chars[start ..< end])
    }
}
