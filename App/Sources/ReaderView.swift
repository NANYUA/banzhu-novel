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
    @State private var slideOffset: CGFloat = 0
    @State private var slideIsHorizontal: Bool?
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
                .onChange(of: contentSize) { _, newSize in
                    viewStore.send(.containerSizeChanged(newSize))
                }
            }
            .navigationTitle("")
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
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
        let displayText = configuration.pageTurnMode == .scroll
            ? viewStore.text
            : currentPageText(viewStore)

        let page = ZStack {
            PageTextView(
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
        .contentShape(Rectangle())
        .animation(
            configuration.pageTurnMode == .scroll
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

    // MARK: - 手势

    @ViewBuilder
    private func readerGesture(
        _ content: some View,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        onCenterTap: @escaping () -> Void
    ) -> some View {
        switch viewStore.config.pageTurnMode {
        case .slide:
            slideGesture(
                content,
                viewStore: viewStore,
                availableWidth: availableWidth,
                onCenterTap: onCenterTap
            )

        case .tap:
            tapGesture(
                content,
                viewStore: viewStore,
                availableWidth: availableWidth,
                onCenterTap: onCenterTap
            )

        case .scroll:
            scrollGesture(
                content,
                availableWidth: availableWidth,
                onCenterTap: onCenterTap
            )
        }
    }

    /// 滑动翻页：≥10pt 迟滞锁横向（§12）→ 1:1 跟手 + 边界橡皮筋（§6 / §9）→ 动量投射 + 速度交接（§12）。
    private func slideGesture(_ content: some View, viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>, availableWidth: CGFloat, onCenterTap: @escaping () -> Void) -> some View {
        content
            .offset(x: slideOffset)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        slideIsHorizontal = slideIsHorizontal ?? (abs(value.translation.width) > abs(value.translation.height))
                        guard slideIsHorizontal == true, !reduceMotion else { return }
                        let raw = value.translation.width, index = viewStore.currentPageIndex
                        let edge = raw > 0 ? index <= 0 : index + 1 >= viewStore.pages.count
                        slideOffset = edge ? raw * availableWidth * 0.55 / (availableWidth + 0.55 * abs(raw)) : raw
                    }
                    .onEnded { value in
                        let wasHorizontal = slideIsHorizontal == true
                        slideIsHorizontal = nil
                        guard wasHorizontal else { return }
                        let projected = value.predictedEndTranslation.width
                        let target = viewStore.currentPageIndex + (projected < 0 ? 1 : -1)
                        if abs(projected) > availableWidth / 2, viewStore.pages.indices.contains(target) {
                            viewStore.send(projected < 0 ? .nextPage : .prevPage)
                        }
                        withAnimation(slideSettleAnimation()) {
                            slideOffset = 0
                        }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if isCenterTap(value.location.x, width: availableWidth) {
                            onCenterTap()
                        }
                    }
            )
    }

    /// 吸附回位动画：**普通缓动，不用弹簧**（U1-9，owner 要求删掉翻页的弹簧效果）。
    ///
    /// 原先这里是 `.interpolatingSpring(stiffness: 300, damping: 28…35, initialVelocity:)`
    /// —— 阻尼比 ζ≈0.8，会过冲回弹。现在换成一条「起始快、末端缓停」的 timing curve：
    /// 观感仍是「一滑就到位」，但不再有过冲。
    ///
    /// 注意：跟手（1:1 位移 + 边界橡皮筋）与抬手后的**动量判向**都保留，
    /// 被去掉的只是回位动画的弹簧曲线本身。副作用是失去了释放速度的交接
    /// （普通缓动没有初速度概念），换来的就是「不弹」。
    private func slideSettleAnimation() -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    }

    private func tapGesture(
        _ content: some View,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        onCenterTap: @escaping () -> Void
    ) -> some View {
        content.gesture(
            SpatialTapGesture()
                .onEnded { value in
                    let locationX = value.location.x
                    if isCenterTap(locationX, width: availableWidth) {
                        onCenterTap()
                    } else if locationX < availableWidth / 2 {
                        viewStore.send(.prevPage)
                    } else {
                        viewStore.send(.nextPage)
                    }
                }
        )
    }

    private func scrollGesture(
        _ content: some View,
        availableWidth: CGFloat,
        onCenterTap: @escaping () -> Void
    ) -> some View {
        content.simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    if isCenterTap(value.location.x, width: availableWidth) {
                        onCenterTap()
                    }
                }
        )
    }

    private func isCenterTap(_ locationX: CGFloat, width: CGFloat) -> Bool {
        locationX >= width / 3 && locationX <= width * 2 / 3
    }

    private func readerChrome(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        VStack {
            readerTopBar(viewStore)

            Spacer()

            readerBottomBar(viewStore)
        }
    }

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

            Button {
                setChromeVisible(false)
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("隐藏控制栏")
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
        .padding(.top, DesignTokens.Spacing.xs)
    }

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
        .padding(.bottom, DesignTokens.Spacing.sm)
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
        .buttonStyle(.plain)
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
    /// 中央点击 / 顶栏 `eye.slash` / 下载后自动隐藏全部走这里，杜绝再次分叉
    /// （此前 `eye.slash` 与下载后是裸赋值，会瞬切而不与中央点击同步过渡）。
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
