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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                ZStack {
                    backgroundColor(for: viewStore.config)
                        .ignoresSafeArea()

                    readerContent(
                        viewStore,
                        availableWidth: geometry.size.width,
                        availableHeight: geometry.size.height
                    )

                    if isChromeVisible {
                        readerChrome(viewStore)
                            .transition(.opacity)
                    }
                }
                .task {
                    viewStore.send(.loadSavedSettings(geometry.size))
                    viewStore.send(
                        .loadChapterWithName(viewStore.chapterPath, viewStore.chapterName)
                    )
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

    @ViewBuilder
    private func readerContent(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        availableHeight _: CGFloat
    ) -> some View {
        if viewStore.isLoading, viewStore.text.isEmpty {
            ProgressView("加载中…")
        } else if let message = viewStore.errorMessage, viewStore.text.isEmpty {
            VStack(spacing: 12) {
                Text("加载失败")
                    .font(.title3.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    viewStore.send(.loadChapter(viewStore.chapterPath))
                }
                .buttonStyle(.borderedProminent)
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
            reduceMotion || configuration.pageTurnMode == .scroll
                ? nil
                : pageAnimation(for: configuration.pageTurnAnimation),
            value: viewStore.currentPageIndex
        )

        return readerGesture(
            page,
            viewStore: viewStore,
            availableWidth: availableWidth,
            onCenterTap: {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                    isChromeVisible.toggle()
                }
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

    private func slideGesture(
        _ content: some View,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        onCenterTap: @escaping () -> Void
    ) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(horizontal) > abs(vertical) else { return }
                    if horizontal < -30 {
                        viewStore.send(.nextPage)
                    } else if horizontal > 30 {
                        viewStore.send(.prevPage)
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
        .background(
            LinearGradient(
                colors: [.black.opacity(0.25), .clear, .black.opacity(0.25)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
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

            Spacer()

            Text(viewStore.chapterName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer()

            Button {
                isChromeVisible = false
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("隐藏控制栏")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(.systemBackground))
                : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func chromeButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
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
        isChromeVisible = false
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

    private func pageTransition(
        for animation: PageTurnAnimation,
        direction: PageTurnDirection
    ) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        switch animation {
        case .none:
            return .identity
        case .cover:
            if direction == .forward {
                return .asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .leading)
                )
            } else {
                return .asymmetric(
                    insertion: .move(edge: .leading),
                    removal: .move(edge: .trailing)
                )
            }
        case .curl:
            if direction == .forward {
                return .asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity)
                )
            } else {
                return .asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.94, anchor: .trailing).combined(with: .opacity)
                )
            }
        }
    }

    private func pageAnimation(for animation: PageTurnAnimation) -> Animation? {
        switch animation {
        case .none:
            nil
        case .cover:
            .easeInOut(duration: 0.2)
        case .curl:
            .easeInOut(duration: 0.3)
        }
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
