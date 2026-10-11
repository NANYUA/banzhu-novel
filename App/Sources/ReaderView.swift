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
    /// 书名：角落状态标签（HUD）在**章节第一页**显示它，其余页显示章节名（`ReaderCornerHUD`）。
    ///
    /// 默认空串 —— `init(store:)` 那条测试 / 预览路径拿不到书名，HUD 据此回退显示章节名。
    let bookTitle: String
    let chapters: [ChapterItem]
    let downloadStore: StoreOf<DownloadFeature>?

    @State private var isShowingSettings = false
    @State private var isShowingDirectory = false
    @State private var isShowingSearch = false
    /// 「更多 → 书籍详情」的 sheet 开关（详情页**覆盖**在阅读页之上，见 `detailSheet`）。
    @State private var isShowingDetail = false
    /// 「下载」按钮弹出的**章节选择面板**开关（口径：下载不再直接入队当前章，统一走面板）。
    @State private var isShowingDownloadPicker = false
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
    /// `chapters` 同时声明给 reducer：到章尾「无缝进下一章」靠它推出下一章。
    ///
    /// `initialOffset` 是「上次读到章内哪个字符偏移」，**只在第一次内容加载时**恢复一次
    /// （`ReaderFeature.consumeInitialOffset` 取出即归零）—— 之后换章 / 从目录跳章仍从章首开始。
    init(
        chapterPath: String,
        chapterName: String = "",
        bookPath: String = "",
        bookTitle: String = "",
        chapters: [ChapterItem] = [],
        downloadStore: StoreOf<DownloadFeature>? = nil,
        initialOffset: Int = 0
    ) {
        self.bookPath = bookPath
        self.bookTitle = bookTitle
        self.chapters = chapters
        self.downloadStore = downloadStore
        store = Store(
            initialState: ReaderFeature.State(
                chapterPath: chapterPath,
                chapterName: chapterName,
                chapters: chapters,
                initialOffset: initialOffset
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
        bookTitle = ""
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
                let contentPaddings = readerContentPaddings(inset: viewStore.config.inset)
                // 正文底色只解析一次：正文层铺底与上下栏的玻璃派生共用它（唯一来源）。
                let pageColor = pageBackgroundColor(for: viewStore.config)
                ZStack {
                    Color(uiColor: pageColor)
                        .ignoresSafeArea()

                    // 正文层：盒顶 = `inset.top`、盒底距屏幕底 = `inset.bottom`
                    // （**距屏幕边缘的绝对距离**，`0` = 贴屏幕边、不避让刘海），
                    // 盒高 = 全屏高 − 两条内边距。`contentSize` 就是这一层渲染盒的尺寸，
                    // 与 `configuration.containerSize` 逐值相同（B0-2 几何契约）。
                    // ⚠️ 竖向**只有这一套机制**：TextKit 侧（`PageTextView` 的
                    // `textContainerInset` 与 `TextKitMeasuring`）竖向一律按 0，两处都算就是双倍。
                    readerContent(
                        viewStore,
                        availableWidth: contentSize.width,
                        availableHeight: contentSize.height
                    )
                    .padding(.leading, geometry.safeAreaInsets.leading)
                    .padding(.trailing, geometry.safeAreaInsets.trailing)
                    .padding(.top, contentPaddings.top)
                    .padding(.bottom, contentPaddings.bottom)
                    // 正文边框标识（阅读设置里的开关）：叠加层挂在上面四条 padding **之后**
                    // ⇒ 它的 frame 是**整屏**，所以这里补「**从屏幕边缘到正文盒**」的**全量**内缩
                    // （横向 = 安全区 + `inset` 左右；竖向 = `contentPaddings`，见 `ReaderTextAreaBorder`）。
                    .readerTextAreaBorder(
                        isOn: viewStore.config.showsTextAreaBorder,
                        insets: EdgeInsets(
                            top: contentPaddings.top,
                            leading: geometry.safeAreaInsets.leading + viewStore.config.inset.leading,
                            bottom: contentPaddings.bottom,
                            trailing: geometry.safeAreaInsets.trailing + viewStore.config.inset.trailing
                        )
                    )

                    // 角落状态标签（HUD）：与正文层 / 控制栏层**并列**的独立叠加层 ——
                    // 不参与正文布局、不占正文空间、不改任何 padding / frame / 分页参数。
                    // ⚠️ 必须加在下面的控制栏层**之前**（owner 口径：控制栏呼出时盖住 HUD）；
                    // 定位与三格内容见 `ReaderCornerHUD.swift` 里的 `readerCornerHUD`。
                    readerCornerHUD(
                        viewStore,
                        pageColor: pageColor,
                        safeAreaInsets: geometry.safeAreaInsets,
                        topPadding: topBarPadding(inset: viewStore.config.topBarInset),
                        // 与下栏面板底边同源：下栏被抬高时 HUD 必须跟着走，
                        // 否则控制栏呼出时盖不住它（这是「HUD 与控制栏同一套外留边」的一半）。
                        bottomPadding: viewStore.config.bottomBarInset
                    )

                    // 控制栏层：与正文层**并列**的叠加层，自己不占正文的布局空间 ⇒
                    // 呼出 / 隐藏不改变正文的分页与阅读位置（设计稿的关键点）。
                    // **只吃横向安全区**（U9-7）：竖向不再被安全区钉住 —— 上栏的上边缘由
                    // `topBarPadding(inset:)` 决定（设置里的「上标签上边距」，默认 0 = 贴屏幕最上边、
                    // 不避让刘海）、下栏的下边缘吃 `bottomBarInset`、跳章条与下栏之间固定 8pt
                    // ⇒ 三条圆角面板能比正文更贴屏幕上下边（见 `ReaderChromeOverlay`）。
                    if isChromeVisible {
                        ReaderChromeOverlay(
                            style: ReaderChromeStyle.make(page: pageColor),
                            chapterTitle: viewStore.chapterName,
                            topPadding: topBarPadding(inset: viewStore.config.topBarInset),
                            // 下栏面板**下边缘**距屏幕底的距离（0 = 贴屏幕最下边）。
                            bottomBarInset: viewStore.config.bottomBarInset,
                            previousChapter: viewStore.previousChapter,
                            nextChapter: viewStore.nextChapter,
                            onBack: { dismiss() },
                            onContents: { isShowingDirectory = true },
                            // 下载：弹出**章节选择面板**（面板里默认勾上「当前章 + 后续预缓存章数」）。
                            // 不再直接入队当前章 —— 统一走面板，而面板已默认勾当前章，
                            // 所以「下载当前章」仍然只是再点一次确认。
                            //
                            // `downloadStore == nil` 时**不打开**：与下面 `onShowDetail` 同一条口径
                            // （不给一个点了什么也不会发生的空壳）。nil 只出现在 `init(store:)`
                            // 那条测试 / 预览路径上 —— 那里 `bookPath` 也是空串，本来就没有书可下。
                            onDownload: {
                                if downloadStore != nil {
                                    isShowingDownloadPicker = true
                                }
                            },
                            onSearch: { isShowingSearch = true },
                            onSettings: { isShowingSettings = true },
                            onShowDetail: onShowDetail,
                            // 上一章 / 下一章走 `.jumpToAdjacentChapter`：相邻章**预加载就绪**时
                            // 直接换章（无 loading，与章尾左滑同一条路），没就绪才回退
                            // `loadChapterWithName` 完整加载。两条路的落页口径**相同**（都是新章章首），
                            // 所以按钮不会因为「缓存好没好」跳到不同的页。
                            onJumpToChapter: { chapter in
                                viewStore.send(.jumpToAdjacentChapter(chapter))
                            },
                            // 本章页码进度条（跳章条中间）：拖到哪一页就立刻翻到哪一页。
                            // `.goToPage` 只迁移位置、**不落盘**（拖动中高频调用）；抬手时
                            // `.pageJumpCommitted` 落盘一次 —— 为什么拆成两个 action 见 ReaderFeature。
                            pageJump: ReaderPageJump(
                                pageIndex: viewStore.currentPageIndex,
                                pageCount: viewStore.pages.count,
                                onJumpToPage: { viewStore.send(.goToPage($0)) },
                                onCommitPageJump: { viewStore.send(.pageJumpCommitted) }
                            )
                        )
                        .padding(.leading, geometry.safeAreaInsets.leading)
                        .padding(.trailing, geometry.safeAreaInsets.trailing)
                    }
                }
                // 加载中正文层不挂手势（见 `readerContent` 的占位分支）⇒ 整屏点击无处可去。
                // 这一层只在「加载中且无正文」时接管（判据在 `chromeToggleTapFallback`），
                // 正文排出来后立即失效：中央点击习惯与平移翻页手势都不受影响。
                .chromeToggleTapFallback(viewStore: viewStore) {
                    setChromeVisible(!isChromeVisible)
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
            // 状态栏只在**控制栏隐藏**时才藏（设计稿：`.statusBarHidden(!showChrome)`）：
            // 呼出控制栏时状态栏可见 —— 这也正是玻璃要往状态栏下面铺的原因；
            // 隐藏控制栏时进入沉浸阅读，状态栏与两栏一起让位。
            // ⚠️ 状态栏可见性会改变**顶部安全区**（无缺口机型 20pt ↔ 0），进而改变
            // `contentSize` 并触发一次重新分页（见下方 `onChange`）—— 阅读位置仍由
            // `characterOffset` 保住（契约 ③），但页断点可能移动一行。
            // 有灵动岛 / 刘海的机型顶部安全区由硬件决定（59pt），不受状态栏影响。
            //
            // 底栏（tabBar）**刻意不在这里声明**：它的可见性全仓只有三个 tab 根视图一个所有者
            // （书架 / 书城 / 搜索），由各自的「正在展示下层页面」状态驱动（U3-5）。
            // 阅读页现在有两条入口 —— 详情页 push（`BookDetailView`）与书架 / 本地页直接 push
            // （`BookshelfView+Reader.swift`）—— 两条入口处，所属 tab 根视图都已经把底栏置为隐藏；
            // 在这里再写一次 `.toolbar(.hidden, for: .tabBar)` 就会多出第二个所有者，
            // 正是 U3-5 修掉的「pop 回根视图后底栏不恢复」那种泄漏。
            .statusBar(hidden: !isChromeVisible)
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
            // 「更多 → 书籍详情」：**sheet 覆盖在阅读页之上**，不是 push。
            // 阅读页自己声明了 `.toolbar(.hidden, for: .navigationBar)`，push 一层详情页会继承
            // 这条隐藏 ⇒ 详情页既没有标题、也没有返回按钮；sheet 自带自己的导航栈，不受影响。
            .sheet(isPresented: $isShowingDetail) {
                detailSheet(viewStore)
            }
            // 「下载」：章节选择面板（内容在 `ReaderView+DownloadPicker.swift`）。
            // 与目录 / 搜索 / 设置同样是 sheet —— **不占正文布局**：弹出与关闭都不改
            // 正文的分页与阅读位置（它只改面板自己那份现取的目录）。
            .sheet(isPresented: $isShowingDownloadPicker) {
                downloadPickerSheet(viewStore)
            }
            .preferredColorScheme(viewStore.config.appearanceMode.preferredColorScheme)
        }
    }
}

private extension ReaderView {
    // MARK: - 内容

    /// 正文盒的竖向两条内边距（2026-10-11 语义变更）。
    ///
    /// `PageInset.top/bottom` 现在的语义是「**距屏幕边缘的绝对距离**」：
    /// `0` = 正文贴到屏幕最边缘（**不自己适配刘海 / 灵动岛**，内容可以被缺口盖住 ——
    /// owner 明确要这个），`78 / 30` = 距上 / 下屏幕边 78 / 30pt。
    /// ⇒ 这里**直接用设定值**，不再牵涉安全区。
    ///
    /// 旧语义（U9-7，已废弃）是「相对安全区向屏幕边缘推的偏移量，可为负」：
    /// 负值在这里把盒子外扩（`max(0, 安全区 − max(0, −inset))`），正值在
    /// `textContainerInset` 生效 —— 那是「外层管负值、内层管正值」的两段式，
    /// 滑杆的 `0…48` 一段在外层完全是空转的。旧数据由
    /// `VerticalInsetDefaultMigration`（key `v3`）重置为新默认。
    ///
    /// ## 竖向只有这一套机制
    /// 竖向边距**全部**由这里的布局 padding 兑现：`UITextView.textContainerInset`
    /// 与 `TextKitMeasuring` 的竖向一律按 **0** 处理（两处都算 ⇒ 边距翻倍，且分页与渲染错位）。
    ///
    /// ⚠️ 盒高必须与本函数**同源**（`readerContentSize` 直接调它）：写成别的等价式会在极端
    /// 滑杆值下与渲染盒不等，分页立刻与实际渲染错位（B0-2）。
    /// 左右两侧另由 `PageInset` 的左右边距设置负责（正值语义未变，走 `textContainerInset`）。
    private func readerContentPaddings(inset: PageInset) -> (top: CGFloat, bottom: CGFloat) {
        (max(0, inset.top), max(0, inset.bottom))
    }

    /// 阅读正文可用的安全区尺寸（全屏减去左右安全区，再按竖向边距收上下）。
    ///
    /// 宽 = 全屏宽 − 左右安全区；高 = 全屏高 − **上面那两条内边距**
    /// —— 刻意与内边距**同源**：渲染盒的实际高度就是「全屏高 − 两条 padding」，
    /// 写成别的等价式（如「安全区盒高 + 外扩量」）会在极端滑杆值下
    /// 与渲染盒不等（`max(0, …)` 已把内边距夹到 0），分页立刻与实际渲染错位（B0-2）。
    /// 左右两侧另由 `PageInset` 的左右边距设置负责（正值语义未变）。
    private func readerContentSize(
        size: CGSize,
        safeAreaInsets: EdgeInsets,
        inset: PageInset
    ) -> CGSize {
        let paddings = readerContentPaddings(inset: inset)
        return CGSize(
            width: max(0, size.width - safeAreaInsets.leading - safeAreaInsets.trailing),
            height: max(0, size.height - paddings.top - paddings.bottom)
        )
    }

    @ViewBuilder
    private func readerContent(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        availableHeight: CGFloat
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
            // 失败态的出口：上下栏（含「返回」）此时可能还没呼出，而页面上只有「重试」。
            // 点击层垫在 CUV **之下** ⇒ 点按钮被上层接住，只有点空白处才呼出 / 收起上下栏。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        setChromeVisible(!isChromeVisible)
                    }
            }
        } else {
            pageContent(viewStore, availableWidth: availableWidth)
                // 正文层**显式**钉到内容盒（`availableHeight` 不再弃用）：盒 = `readerContentSize`
                // 的派生值 = `configuration.containerSize`（B0-2），不再靠 `.frame(maxHeight:.infinity)`
                // 撑。`.clipped()` 是「正文盒之下不许出现正文」的**结构性**兜底 —— 非滚动
                // `UITextView` 的固有高 = 内容高，SwiftUI 给它的 frame 可能比盒高（owner 真机复测
                // 「正文内容还是会越过下边距标线」就是这条路）：钉到盒 + 裁到盒，正文才出不去。
                // `alignment: .topLeading`：即使某帧 frame 比盒高（尺寸同步前的瞬时），也从盒顶起排、
                // 只往下越（被 `.clipped()` 裁掉），不会居中把正文顶出盒子顶部。
                .frame(width: availableWidth, height: availableHeight, alignment: .topLeading)
                .clipped()
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
        let slice = currentPageSlice(viewStore)
        return PageTextView(
            text: slice.text,
            configuration: configuration,
            startsAtParagraphStart: slice.startsAtParagraphStart
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 正文永远不接受命中测试：手势统一挂在外层（`slideGesture`），
        // 否则 `UITextView` 会把拖拽吞掉（原先只有滚动方式才打开命中测试，滚动已删）。
        .allowsHitTesting(false)
        .id(pageIdentity(viewStore))
        .transition(pageTransition())
    }

    private func directorySheet(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        NavigationStack {
            List(chapters) { chapter in
                // `insetGrouped` 只在分组首 / 末行给卡面圆角，强调层必须逐角跟随（见下面的 `shape`）。
                let isFirstChapter = chapter.path == chapters.first?.path
                let isLastChapter = chapter.path == chapters.last?.path
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
                    // 左右内边距改由标签自己持有：下面 `listRowInsets` 水平归零后标签铺满整张卡，
                    // 强调层才能覆盖**含内边距在内的整行**（真机反馈：原来只到文字与勾之间）。
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                // §9 按下反馈：`.plain` 在 `List` 行里按下只压暗标签内容（真机反馈「目录下
                // 按下无效果」），行/卡面颜色不变。改用项目既有的 `PressableCardButtonStyle`：
                // 按下瞬间叠一层可见强调层 + 轻微缩放，抬手复原；强调层轮廓逐角跟随系统卡面
                // 圆角 —— 铺满整卡后若一律用直角，分组首 / 末行就会在圆角外露出方角。
                .buttonStyle(PressableCardButtonStyle(
                    pressedScale: 0.99,
                    shape: AnyShape(UnevenRoundedRectangle(
                        topLeadingRadius: isFirstChapter ? DesignTokens.Radius.sm : 0,
                        bottomLeadingRadius: isLastChapter ? DesignTokens.Radius.sm : 0,
                        bottomTrailingRadius: isLastChapter ? DesignTokens.Radius.sm : 0,
                        topTrailingRadius: isFirstChapter ? DesignTokens.Radius.sm : 0
                    ))
                ))
                // 水平也归零：标签铺满整张卡 ⇒ 强调层覆盖整行，行高与文字缩进都不变。
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                // 分隔线起点仍留在原内容缩进处（行内边距归零后它本来会跑到卡片边缘）。
                .alignmentGuide(.listRowSeparatorLeading) { _ in DesignTokens.Spacing.md }
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

    // MARK: - 书籍详情（更多菜单）

    /// 「更多 → 书籍详情」的落点。`nil` = 菜单里不出现这一项。
    ///
    /// 两个前提缺一不可：
    /// - **知道 `bookPath`**：详情页按它加载，空路径只会得到一张空壳；
    /// - **拿到下载队列 store**：`BookDetailView` 的必需参数（「下载章节」要用它）。
    ///
    /// 二者同时缺的只有 `init(store:)` 那条测试 / 预览路径（`bookPath` 为空、`downloadStore` 为 nil）
    /// —— 那里不给入口，而不是给一个点了打不开的空壳。
    private var onShowDetail: (() -> Void)? {
        guard !bookPath.isEmpty, downloadStore != nil else { return nil }
        return { isShowingDetail = true }
    }

    /// 详情页 sheet 的内容：自带一层 `NavigationStack`。
    ///
    /// 详情页是按「被 push」设计的（标题与「转到原网站」都挂在导航栏上），
    /// 所以覆盖层里要给它一条自己的栏，并补一个「完成」用来关掉。
    ///
    /// 标题传空串：`BookDetailView` 的 `fallback` 只是首帧占位，
    /// `BookDetailFeature.onAppear` 会立刻用本地快照 / 联网结果把它填上 ——
    /// 这里的 `title` 与书名无关，所以阅读页**已经**有 `bookTitle`（HUD 左上角要用）也不往这里传。
    ///
    /// ## ⚠️ `onOpenReader`：sheet 里点阅读入口**不能**再 push 一层阅读页（修 4）
    /// `BookDetailView` 默认会自己 `navigationDestination` 出阅读页，而在本 sheet 里那层
    /// 阅读页是**叠在阅读页之上**的第二层全屏阅读页 ⇒ 卡死（owner 真机反馈）。
    /// 这里注入回调接管：先关掉 sheet，再让**下面那层**阅读页跳到该章 ——
    /// 走的是与目录 / 搜索跳章**完全同一条** action（`loadChapterWithName`），
    /// 不新增任何加载路径。
    @ViewBuilder
    private func detailSheet(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> some View {
        if let downloadStore {
            NavigationStack {
                BookDetailView(
                    bookPath: bookPath,
                    title: "",
                    downloadStore: downloadStore,
                    onOpenReader: { chapter in
                        isShowingDetail = false
                        viewStore.send(.loadChapterWithName(chapter.path, chapter.name))
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            isShowingDetail = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - 控制栏显隐

    /// 控制栏显隐的**唯一**写入口（U1-2）。
    ///
    /// 上栏与下栏都装在 `ReaderChromeOverlay` 里（`ReaderView+Chrome.swift`），
    /// 由 body 里同一个 `if isChromeVisible` 控制：两者在物理上无法分别隐藏，
    /// 所以显隐的**时机与动画也必须只有一处决定**。中央点击翻出 / 收起控制栏走这里；
    /// 动画曲线也只在 `ReaderView.chromeToggleAnimation(reduceMotion:)` 定义一次，杜绝分叉。
    private func setChromeVisible(_ visible: Bool) {
        guard isChromeVisible != visible else { return }
        withAnimation(Self.chromeToggleAnimation(reduceMotion: reduceMotion)) {
            isChromeVisible = visible
        }
    }

    // MARK: - 页面身份

    /// 页面身份 = **章节路径 + 页码**：换章时身份必须变化，否则章尾无缝进下一章若停在
    /// `0 → 0`（旧章只有 1 页），Reduce Motion 的单页 `.opacity` 转场就不会播（内容会换但像硬切）。
    private func pageIdentity(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        "\(viewStore.chapterPath)-\(viewStore.currentPageIndex)"
    }

    // MARK: - 分页定位

    /// 取当前页对应的文本片段 + 「本页是否从段落开头开始」（首行缩进的判据）。
    ///
    /// 判据只此一处：调 NovelCore 的 `ParagraphBoundary`，度量侧 `TextKitMeasuring` 用的是同一条。
    private func currentPageSlice(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> (text: String, startsAtParagraphStart: Bool) {
        let pages = viewStore.pages
        let offset = viewStore.currentOffset
        let text = viewStore.displayText

        // 兜底（还没分页 / 定位不到）时整章当一页渲染、从 0 起排 ⇒ 一定是段落开头。
        guard !pages.isEmpty, !text.isEmpty else { return (text, true) }
        guard let page = pages.first(where: { offset >= $0.location && offset < $0.location + $0.length }) else {
            return (text, true)
        }
        let chars = Array(text)
        let start = min(page.location, chars.count)
        let end = min(page.location + page.length, chars.count)
        guard start < end else { return ("", true) }
        return (String(chars[start ..< end]), ParagraphBoundary.isParagraphStart(chars, at: start))
    }
}
