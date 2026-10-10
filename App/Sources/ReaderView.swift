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
                    safeAreaInsets: geometry.safeAreaInsets,
                    inset: viewStore.config.inset
                )
                let contentPaddings = readerContentPaddings(
                    safeAreaInsets: geometry.safeAreaInsets,
                    inset: viewStore.config.inset
                )
                ZStack {
                    backgroundColor(for: viewStore.config)
                        .ignoresSafeArea()

                    // 正文层：盒顶 = 安全区顶 − 外扩量、盒高 = 全屏高 − 两条内边距（U9-7）。
                    // `contentSize` 就是这一层渲染盒的尺寸，与 `configuration.containerSize`
                    // 逐值相同（B0-2 几何契约）。
                    readerContent(
                        viewStore,
                        availableWidth: contentSize.width,
                        availableHeight: contentSize.height
                    )
                    .padding(.leading, geometry.safeAreaInsets.leading)
                    .padding(.trailing, geometry.safeAreaInsets.trailing)
                    .padding(.top, contentPaddings.top)
                    .padding(.bottom, contentPaddings.bottom)

                    // 控制栏层：**只吃横向安全区**，竖向不再被安全区钉住 —— 两栏各自带竖向
                    // 内边距（见 `readerChrome`），因此能比正文更贴屏幕上下边（U9-7）。
                    // 它浮在正文之上（`isChromeVisible`），与正文重叠是预期行为：
                    // 栏是临时覆盖层，不为避让去改正文布局。
                    if isChromeVisible {
                        readerChrome(
                            viewStore,
                            topPadding: topBarPadding(safeAreaInsets: geometry.safeAreaInsets)
                        )
                        .padding(.leading, geometry.safeAreaInsets.leading)
                        .padding(.trailing, geometry.safeAreaInsets.trailing)
                        .transition(.opacity)
                    }
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

    /// 正文盒的竖向两条内边距（U9-7）。
    ///
    /// `PageInset.top/bottom` 允许为负，语义是「**相对安全区向屏幕边缘推**的偏移量」：
    /// 盒子要向上/向下外扩 `max(0, -inset)`，盒顶/盒底各外移同样距离
    /// ⇒ 内边距 = `安全区 − 外扩量`，下限 0（外扩超过安全区时盒子顶到屏幕边为止）。
    /// 正值时外扩为 0，内边距与旧实现**逐值相同** ⇒ 用户加正边距的行为完全不变。
    ///
    /// ⚠️ 负值**不能**直接进 `UITextView.textContainerInset`：`clipsToBounds` 默认 `true`，
    /// 负 inset 只会把正文裁掉而不是往外扩。外扩因此由这里的布局兑现，
    /// 传给 TextKit 的竖向 inset 一律 clamp 到 `>= 0`
    /// （`PageTextView` 与 `TextKitMeasuring` 各一处，后者关系分页，漏了就与渲染错位）。
    private func readerContentPaddings(
        safeAreaInsets: EdgeInsets,
        inset: PageInset
    ) -> (top: CGFloat, bottom: CGFloat) {
        (
            max(0, safeAreaInsets.top - max(0, -inset.top)),
            max(0, safeAreaInsets.bottom - max(0, -inset.bottom))
        )
    }

    /// 阅读正文可用的安全区尺寸（全屏减去状态栏 / 灵动岛 / Home Indicator，再按竖向边距外扩）。
    ///
    /// 宽 = 全屏宽 − 左右安全区；高 = 全屏高 − **上面那两条内边距**
    /// —— 刻意与内边距**同源**：渲染盒的实际高度就是「全屏高 − 两条 padding」，
    /// 写成别的等价式（如「安全区盒高 + 外扩量」）会在「外扩量 > 安全区」的极端滑杆值下
    /// 与渲染盒不等（`max(0, …)` 已把内边距夹到 0），分页立刻与实际渲染错位（B0-2）。
    /// 左右两侧另由 `PageInset` 的左右边距设置负责（正值语义未变）。
    private func readerContentSize(
        size: CGSize,
        safeAreaInsets: EdgeInsets,
        inset: PageInset
    ) -> CGSize {
        let paddings = readerContentPaddings(safeAreaInsets: safeAreaInsets, inset: inset)
        return CGSize(
            width: max(0, size.width - safeAreaInsets.leading - safeAreaInsets.trailing),
            height: max(0, size.height - paddings.top - paddings.bottom)
        )
    }

    /// 上栏最多可上移的量：理论极限 ≈ 38pt（栏顶 21pt）只剩 0.7pt 余量，太紧 —— 字体度量是
    /// 查表估的，估错 1pt 标题就会被灵动岛咬 ⇒ 收紧到 34pt。推导见 `topBarPadding(safeAreaInsets:)`。
    private static let topBarMaxUpwardShift: CGFloat = 34

    /// 上栏的上移量（U9-7）：`T = max(Spacing.xs, safeAreaInsets.top − 34)`。
    ///
    /// 上栏的**标题是居中**的，与灵动岛同一列 ⇒ 标题字形必须落在灵动岛下沿（约 48pt）以下。
    /// 栏内结构是「`Spacing.sm`(12) 内边距 + 44pt 内容行 + 12 内边距」，标题在 44pt 行内垂直
    /// 居中，其字形顶距栏顶约 27pt ⇒ 栏顶 ≥ 48 − 27 ≈ 21pt 即可（理论上限 59 − 21 ≈ 38pt，
    /// 但那样只剩 0.7pt 余量）。取 34pt ⇒ 栏顶 59 − 34 = **25pt**，标题字形顶 ≈ 25 + 27 = 52pt，
    /// 距下沿约 **5.7pt**。栏顶仍进到灵动岛覆盖区（25pt < 48pt）—— 那是预期的：被覆盖的
    /// 那部分是栏的**空内边距**。下限 `Spacing.xs`(8) 保证无灵动岛 / 无刘海机型上栏也不贴死屏幕边。
    private func topBarPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        max(DesignTokens.Spacing.xs, safeAreaInsets.top - Self.topBarMaxUpwardShift)
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
            usesPan ? nil : pageAnimation(),
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

    /// 单页渲染：唯一翻页方式（左右滑动）用，平移不可用（Reduce Motion、未分页）时也用它兜底。
    private func singlePage(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        configuration: PaginationConfiguration
    ) -> some View {
        PageTextView(
            text: currentPageText(viewStore),
            configuration: configuration
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 正文永远不接受命中测试：手势统一挂在外层（`slideGesture`），
        // 否则 `UITextView` 会把拖拽吞掉（原先只有滚动方式才打开命中测试，滚动已删）。
        .allowsHitTesting(false)
        .id(pageIdentity(viewStore))
        .transition(pageTransition())
    }

    // MARK: - 控制栏

    /// 上下两栏（浮在正文之上的临时覆盖层，`isChromeVisible` 控制显隐）。
    ///
    /// 位置（U9-7）：这一层**不再吃竖向安全区**，竖向位置完全由两栏各自的内边距决定 ——
    /// 上栏 `.padding(.top, topPadding)`、下栏 `.padding(.bottom, Spacing.xs)`，
    /// 因此两栏能比正文更贴屏幕上下边（正文还受灵动岛 / Home Indicator 约束）。
    /// 栏高、栏内按钮、圆角、面板颜色、横向 `Spacing.md` 内边距**一律未动**。
    private func readerChrome(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        topPadding: CGFloat
    ) -> some View {
        VStack {
            readerTopBar(viewStore)
                .padding(.top, topPadding)

            Spacer()

            readerBottomBar(viewStore)
                // 下栏贴到屏幕底 8pt 处：栏自身 `Spacing.sm`(12) 的内边距正好容下底部
                // 那根约 5pt 的 Home Indicator 细条（按钮落在细条上方，不会被压）。
                .padding(.bottom, DesignTokens.Spacing.xs)
        }
    }

    /// 上栏。
    ///
    /// 位置（U9-7）：整条 `readerChrome` 已不再吃竖向安全区，上栏的上边缘由
    /// `readerChrome` 给的 `topPadding`（推导见 `topBarPadding(safeAreaInsets:)`）决定，
    /// 目标是「标题字形正好落在灵动岛下沿以下」—— 比正文贴得更上，
    /// 但字形仍不会被灵动岛盖住。圆角半径本身**不猜**：不同机型一律由安全区自适应。
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
            backgroundColor(for: viewStore.config),
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
    /// 位置（U9-7）与上栏同理：这一层不再吃竖向安全区，下栏的下边缘由 `readerChrome`
    /// 给的 `.padding(.bottom, Spacing.xs)`(8) 决定 —— 比正文贴得更下，
    /// 栏自身 12pt 内边距正好把 Home Indicator 那根细条让在空处。
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
            backgroundColor(for: viewStore.config),
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
        // §9 按下反馈：`.plain` 按下零反馈。强调层贴按钮自身的 `Radius.xs`(6) 圆角矩形：
        // 按钮四周内缩 `Spacing.sm`(12)，外面这根材质条圆角 `Radius.lg`(18)，
        // 故 6 = 18 - 12，强调层才能**彻底**落在栏的圆角之内。
        // （原先的 12 只是缓解 —— 对角方向仍会露出约 2.5pt 方角。）
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs))))
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
                    // 行内边距由标签自己持有（配合下面的 `listRowInsets`）：竖向 `Spacing.sm`(12)
                    // 撑出 44pt 以上命中区，强调层才能覆盖**整行**，而不只是文字那一条。
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                // §9 按下反馈：`.plain` 在 `List` 行里按下只压暗标签内容（真机反馈「目录下
                // 按下无效果」），行/卡面颜色不变。改用项目既有的 `PressableCardButtonStyle`：
                // 按下瞬间叠一层可见强调层 + 轻微缩放，抬手复原。
                // 强调层圆角取 `Radius.sm`(12)：本行没有自绘卡面（不像书架书卡），轮廓是系统
                // 行背景；强调层水平内缩 `Spacing.md`(16)、垂直不出本行 ⇒ 圆角不会露到行外。
                .buttonStyle(PressableCardButtonStyle(
                    pressedScale: 0.99,
                    shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                ))
                // 竖向 0 + 水平 16（= `insetGrouped` 系统默认行内边距）：左右缩进与行高都不变，
                // 只是把竖向那约 11pt 让给标签自己 ⇒ 强调层铺满整行高度。水平仍留 16 的原因：
                // 系统卡面的圆角在行两端，强调层内缩后才不会在圆角外露出方角。
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: DesignTokens.Spacing.md,
                    bottom: 0,
                    trailing: DesignTokens.Spacing.md
                ))
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

    /// 阅读页**正文底色**的唯一来源（上下两栏同色，也用这一个）。
    /// 返回 `Color(uiColor:)` 包出来的动态色，跟随当前明暗外观解析。
    private func backgroundColor(for configuration: PaginationConfiguration) -> Color {
        Color(uiColor: configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor,
            customDark: configuration.customBackgroundColorDark
        ))
    }

    private func pageIdentity(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        "page-\(viewStore.currentPageIndex)"
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
