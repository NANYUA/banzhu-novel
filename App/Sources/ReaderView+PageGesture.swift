import ComposableArchitecture
import NovelCore
import SwiftUI

/// 速度采样最多留几个点（本次手势的 `onChanged` 逐帧追加）。
///
/// 8 个点在 60Hz 下覆盖约 130ms —— 够 `PanExitTracking.velocityWindow` 的 90ms 窗口，
/// 又不会让长手势把数组撑大。判退阈值与窗口本身在 `PanExitTracking` 里，此处只管容量。
private let slideSampleLimit = 8

/// 全景图里的一格：身份 + 该格要渲染的文本 + 相对当前页的格数。
///
/// 放在文件级而不是嵌在 `ReaderView` 里：它只是渲染数据，没有身份。
private struct PanSlot: Identifiable {
    /// 一格的身份 = 「**哪一章**的第几页」。
    ///
    /// 跨章时必须靠它保持身份：换章后原本摆在 `+1` 格上的「下一章第 1 页」正好变成当前页，
    /// 身份不变 ⇒ SwiftUI 复用同一个 `PageTextView`（正文与配置逐字未变，`updateUIView`
    /// 直接返回），平移因此是连续的，不会先闪一下。只按下标做身份就会整条重建。
    struct Identity: Hashable {
        let path: String
        let index: Int
    }

    let id: Identity
    let text: String

    /// 本格是否**从段落开头**开始（首行缩进判据；由 `pageText` 一并算出，见那里的说明）。
    let startsAtParagraphStart: Bool

    let relativeIndex: Int
}

/// 阅读页的翻页手势，以及「平移翻页」（全景图式左右平移）的全景图内容。
///
/// 从 `ReaderView.swift` 拆出来的：那个文件已经贴近 SwiftLint `file_length` 600 的硬门，
/// 而手势与全景图渲染是其中最独立的一块，搬走不改行为。
///
/// 注意：这些成员原本是 `private`（Swift 的 `private` 是本文件级的），
/// 拆文件后改为**模块内可见**，`ReaderView` 里那四个跟手用的 `@State` 也同步放开
/// —— 与 `ReaderView+PageTurn.swift` 同一处理。
extension ReaderView {
    // MARK: - 平移翻页的开关

    /// 是否走「平移翻页」（U9-4）：滑动方式 + 允许动效 + 已分页。
    ///
    /// 这一个判据同时决定两件事，所以**只能有一处**：
    /// - `ReaderView.pageContent` 用它决定铺全景图还是单页；
    /// - `settlePan` 用它决定要不要做「补一页再归零」那步走位。
    ///
    /// 三种情况退回单页：不是滑动方式（点击 / 滚动各有自己的手势与转场）/
    /// Reduce Motion（§13：不做位移，转场沿用既有 `.opacity`）/ 还没分页
    /// （此时单页那支会把整章当一页兜底，不会白屏）。
    func usesPanTurning(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> Bool {
        viewStore.config.pageTurnMode == .slide && !reduceMotion && !viewStore.pages.isEmpty
    }

    /// 是否「**全书第 1 页**」= 第 1 章第 1 页 —— 右滑退出本书只在这一页生效。
    ///
    /// 三个条件缺一不可：
    /// - `currentPageIndex == 0`：章内第 1 页（`pages` 为空时它是 `-1`，一并挡掉）；
    /// - `previousChapter == nil`：第 1 章；
    /// - `previousPages.isEmpty`：上一章确实没预加载出页来（与 `panSlots` / `panGeometry`
    ///   渲染 `-1` 格用的是**同一个判据**，不另立一份）。
    ///
    /// ⚠️ 必须与 `chapters` 非空联合判定：`previousChapter == nil` 还有「章列表还没加载」
    /// 这个成因，只认它会把**任意一章的第 1 页**误判成全书第 1 页 ⇒ 误退。
    ///
    /// ⚠️ 单章书（`chapters.count == 1`）天然满足本判据 —— 它的第 1 章第 1 页就是全书第 1 页，
    /// 右滑退出正是 owner 要的行为。
    func isBookFirstPage(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> Bool {
        guard !viewStore.chapters.isEmpty else { return false }
        return viewStore.currentPageIndex == 0
            && viewStore.previousChapter == nil
            && viewStore.previousPages.isEmpty
    }

    // MARK: - 手势入口

    /// 阅读页唯一的手势：左右滑动翻页（`PageTurnMode` 只剩 `.slide`，点击 / 滚动两套手势已删）。
    /// 中央点击呼出 / 收起控制栏仍由 `slideGesture` 里那个 `SpatialTapGesture` 负责。
    func readerGesture(
        _ content: some View,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        onCenterTap: @escaping () -> Void
    ) -> some View {
        slideGesture(
            content,
            viewStore: viewStore,
            availableWidth: availableWidth,
            onCenterTap: onCenterTap
        )
    }

    // MARK: - 平移翻页（全景图）

    /// 全景图：当前页 + 相邻页铺成一条，跟着手指一起平移。
    ///
    /// **一次最多一页**：相邻页只差一页宽，而跟手位移被 `PagePanTracking.panOffset`
    /// 夹在一页之内，所以屏幕上永远最多只看到「当前页 + 一页」。
    ///
    /// `+1` 那一格在当前是**本章最后一页**、且下一章第 1 页已就绪时渲染下一章的第 1 页
    /// —— 换章因此就是一次普通的「下一页」平移（落位见 `settlePan`）。
    func panPages(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) -> some View {
        ForEach(panSlots(viewStore)) { slot in
            panPage(
                text: slot.text,
                startsAtParagraphStart: slot.startsAtParagraphStart,
                configuration: viewStore.config
            )
            .offset(x: slideOffset + CGFloat(slot.relativeIndex) * availableWidth)
            // §13：相邻格只是「露出来的下一张」，不该进 VoiceOver 焦点 ——
            // 否则读屏会顺着把下一章内容也念一遍（单页时代只有一页，不存在这个问题）。
            .accessibilityHidden(slot.relativeIndex != 0)
        }
    }

    /// 全景图此刻该铺的格：`[-1, 0, +1]`，越界的不铺。
    ///
    /// `+1` 格有两支：本章还有下一页就用本章的；已经是本章最后一页、且下一章第 1 页
    /// 已就绪（`nextPages` 非空）就用**下一章的第 1 页**；两者都不是（最后一章 / 还没
    /// 预加载完）就不铺 —— 那一格空着，`PagePanTracking.turn` 同样判 `.none`（回弹，不提示）。
    ///
    /// `-1` 格是它的**镜像**：已经是本章第一页、且上一章最后一页已就绪（`previousPages`
    /// 非空）就用**上一章的最后一页**；两者都不是（第一章 / 还没预加载完）就不铺
    /// —— 那一格空着，`turn` 同样判 `.none`（回弹，不提示）。
    private func panSlots(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> [PanSlot] {
        let current = viewStore.currentPageIndex
        let pages = viewStore.pages
        return [-1, 0, 1].compactMap { relative in
            let index = current + relative
            if pages.indices.contains(index) {
                let slice = pageText(at: index, in: pages, text: viewStore.displayText)
                return PanSlot(
                    id: PanSlot.Identity(path: viewStore.chapterPath, index: index),
                    text: slice.text,
                    startsAtParagraphStart: slice.startsAtParagraphStart,
                    relativeIndex: relative
                )
            }
            guard !pages.isEmpty else { return nil }
            if relative == 1, current == pages.count - 1, !viewStore.nextPages.isEmpty {
                let slice = pageText(at: 0, in: viewStore.nextPages, text: viewStore.nextDisplayText)
                return PanSlot(
                    id: PanSlot.Identity(path: viewStore.nextChapter?.path ?? "", index: 0),
                    text: slice.text,
                    startsAtParagraphStart: slice.startsAtParagraphStart,
                    relativeIndex: 1
                )
            }
            guard relative == -1, current == 0, !viewStore.previousPages.isEmpty else { return nil }
            let lastIndex = viewStore.previousPages.count - 1
            let slice = pageText(
                at: lastIndex,
                in: viewStore.previousPages,
                text: viewStore.previousDisplayText
            )
            return PanSlot(
                id: PanSlot.Identity(path: viewStore.previousChapter?.path ?? "", index: lastIndex),
                text: slice.text,
                startsAtParagraphStart: slice.startsAtParagraphStart,
                relativeIndex: -1
            )
        }
    }

    /// 全景图里的一格。**不接受命中测试**：手势挂在外面那层（见 `slideGesture`）。
    private func panPage(
        text: String,
        startsAtParagraphStart: Bool,
        configuration: PaginationConfiguration
    ) -> some View {
        PageTextView(
            text: text,
            configuration: configuration,
            startsAtParagraphStart: startsAtParagraphStart
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// 指定页的文本片段 + 「本页是否从段落开头开始」（首行缩进的判据）；
    /// 越界返回空串 + `true`（与 `currentPageSlice` 的区别：不做「整章兜底」）。
    ///
    /// 文本**显式传入**：当前章（`displayText`）与预加载的下一章（`nextDisplayText`）
    /// 共用这一份切片逻辑，不复制第二份。
    ///
    /// 段落判据走 NovelCore 的 `ParagraphBoundary`（度量侧 `TextKitMeasuring` 用的是**同一条**），
    /// 不在 App 里另写一份。
    private func pageText(
        at pageIndex: Int,
        in pages: [PageRange],
        text: String
    ) -> (text: String, startsAtParagraphStart: Bool) {
        guard pages.indices.contains(pageIndex), !text.isEmpty else { return ("", true) }
        let page = pages[pageIndex]
        let chars = Array(text)
        let start = min(page.location, chars.count)
        let end = min(page.location + page.length, chars.count)
        guard start < end else { return ("", true) }
        return (String(chars[start ..< end]), ParagraphBoundary.isParagraphStart(chars, at: start))
    }

    // MARK: - 滑动手势

    /// 滑动 / 平移翻页的手势接线。
    ///
    /// **手势本身的口径没变**（U0-8 / U0-8b 已验收）：≥10pt 迟滞锁横向 → 1:1 跟手 +
    /// 边界橡皮筋 → 抬手用动量投射决定落点。变的是两件事（U9-4）：
    /// 1. 跟手量走 `PagePanTracking.panOffset`（在 `SlideTracking` 之上加**单页约束**）；
    /// 2. 判页走 `PagePanTracking.turn`（**两页中线是否越过屏幕中线**），
    ///    并且松手后**把平移走完**再归零，而不是只把当前页滑回原位。
    ///
    /// 两者喂的是**同一份 `PagePanGeometry`**（`panGeometry(_:availableWidth:)`）——
    /// 章尾 / 章首「相邻章已就绪就不算边界」这条判据只有一处，跟手与判页不会分叉。
    ///
    /// 跟手基数是**抓取瞬间页面真实显示的位置**（方案 A）：吸附回位动画没跑完就再抓时
    /// 从当前显示位置继续，而不是从 0 重开。呈现值怎么来的见
    /// `ReaderView+SlideTracking.swift`，纯数学见 `PagePanTracking`。
    private func slideGesture(
        _ content: some View,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat,
        onCenterTap: @escaping () -> Void
    ) -> some View {
        content
            // 探针只回报呈现值、不参与渲染；页面仍由各页自己的 `.offset` 平移。
            .background(SlidePresentationProbe(offset: slideOffset, presentation: slidePresentation))
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        trackSlide(value, viewStore: viewStore, availableWidth: availableWidth)
                    }
                    .onEnded { value in
                        endSlide(value, viewStore: viewStore, availableWidth: availableWidth)
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        // 中央 1/3 = 呼出 / 收起控制栏（既有行为），左 / 右 1/3 = 点击翻页。
                        // 三支的判定都在 `handleReaderTap` 里，本手势只负责把落点递进去。
                        handleReaderTap(
                            value.location.x,
                            width: availableWidth,
                            viewStore: viewStore,
                            onCenterTap: onCenterTap
                        )
                    }
            )
    }

    /// 手指移动：锁轴 + 从当前显示位置继续跟手。
    private func trackSlide(
        _ value: DragGesture.Value,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) {
        slideIsHorizontal = slideIsHorizontal ?? (abs(value.translation.width) > abs(value.translation.height))
        guard slideIsHorizontal == true, !reduceMotion else { return }
        // 速度采样（只给「全书第 1 页右滑退出」用，判页不读它）：逐帧追加、只留最近几个
        // —— 抬手时按最近 90ms 算速度。数组在抬手处清空，不跨手势累积。
        slideSamples.append(
            PanExitSample(
                translation: value.translation.width,
                timestamp: value.time.timeIntervalSinceReferenceDate
            )
        )
        if slideSamples.count > slideSampleLimit {
            slideSamples.removeFirst(slideSamples.count - slideSampleLimit)
        }
        // 基线只在本次手势的第一次 onChanged 采一次：之后 translation 是
        // 相对同一个起点累积的，逐帧重采就会把已跟手走的位移当成新基线而滚雪球。
        let baseline = slideBaseline ?? slidePresentation.offset
        slideBaseline = baseline
        slideOffset = panOffset(
            from: baseline,
            translation: value.translation.width,
            geometry: panGeometry(viewStore, availableWidth: availableWidth)
        )
    }

    /// 抬手：判页 + 落位；**全书第 1 页**上够远的右滑改成退出本书。
    private func endSlide(
        _ value: DragGesture.Value,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) {
        let wasHorizontal = slideIsHorizontal == true
        // 基线与轴向锁都要在判定**之前**取走：下面两行会把它复位。
        let baseline = slideBaseline ?? 0
        slideIsHorizontal = nil
        slideBaseline = nil
        guard wasHorizontal else { return }
        // 全书第 1 页 + 够远的右滑 ⇒ 直接退出（系统返回动画 = `dismiss()`，不跟手、不播回位动画）。
        // 距离与速度的阈值全在 `PanExitTracking` 里，这里只负责「递进采样、拿回结论」。
        // 方向判据（`> 0`）留在调用点：纯函数只按需求写「够距离 / 够快」，不替调用方定方向。
        let shouldExitBook = value.translation.width > 0 && PanExitTracking.exitsBook(
            translation: value.translation.width,
            availableWidth: availableWidth,
            samples: slideSamples,
            isBookFirstPage: isBookFirstPage(viewStore)
        )
        if shouldExitBook {
            slideSamples = []
            slideOffset = 0
            dismiss()
            return
        }
        slideSamples = []
        // 跟手与判页**共用同一份几何**（同一次手势、同一个 `has*ChapterPage`）：
        // 分叉一次就会出现「能跟手拉过去、松手却不换章」这类错位。
        let geometry = panGeometry(viewStore, availableWidth: availableWidth)
        let turn = PagePanTracking.turn(
            trackedOffset: panOffset(
                from: baseline,
                translation: value.translation.width,
                geometry: geometry
            ),
            translation: value.translation.width,
            predictedEndTranslation: value.predictedEndTranslation.width,
            geometry: geometry
        )
        settlePan(turn, viewStore: viewStore, availableWidth: availableWidth)
    }

    /// 本次手势的几何：页宽 + 当前页下标 + 总页数 + 相邻章是否已就绪。
    ///
    /// `hasNextChapterPage` / `hasPreviousChapterPage` 与 `panSlots` 渲染相邻那一格
    /// 用的是**同一个条件**（`nextPages` / `previousPages` 非空）：非空 ⇒ 那一格摆的是
    /// 下一章第 1 页 / 上一章最后一页 ⇒ 章尾 / 章首不算边界，跟手与章内一致；
    /// 空 ⇒ 那一格空着 ⇒ 保留橡皮筋，不把空白拉出来。
    ///
    /// 非 private：点击翻页要**复用同一份几何**（见 `ReaderView+TapTurn.swift` 的 `turnPage`），
    /// 章界判据不能出现第二份 —— 与 `usesPanTurning` 同一处理（`private` 是本文件级的）。
    func panGeometry(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) -> PagePanGeometry {
        PagePanGeometry(
            availableWidth: availableWidth,
            pageIndex: viewStore.currentPageIndex,
            pageCount: viewStore.pages.count,
            // 下一章第 1 页已就绪 ⇒ 本章最后一页仍可继续 `.next`（换章）。
            hasNextChapterPage: !viewStore.nextPages.isEmpty,
            // 上一章最后一页已就绪 ⇒ 本章第一页仍可继续 `.previous`（退章）。
            hasPreviousChapterPage: !viewStore.previousPages.isEmpty
        )
    }

    /// 跟手位移：纯数学在 `PagePanTracking`，这里只负责把 `@State` 递进去。
    private func panOffset(
        from baseline: CGFloat,
        translation: CGFloat,
        geometry: PagePanGeometry
    ) -> CGFloat {
        PagePanTracking.panOffset(
            fromDisplayedOffset: baseline,
            translation: translation,
            geometry: geometry
        )
    }

    /// 松手落位：翻页就把平移**走完**，不翻页就滑回本页。
    ///
    /// 翻页那一支先把偏移补上一页再动画归零：换页之后「新的当前页」就是原来摆在旁边那一页，
    /// 补一页后它**此刻的屏幕位置完全没变**，接着的动画是连续的平移，不是「先跳一下再滑」。
    /// 这也是「像全景图滑动，但停留在正文页」的落地点 —— 全程只走一页，不连续滚动。
    ///
    /// **章尾换章 / 章首退章走的是同一条路**：此刻 `+1` 格上摆的就是下一章第 1 页
    /// （`-1` 格上摆的是上一章最后一页），换章后它正好变成当前页 —— 补位那一步与章内
    /// 翻页**逐值相同**，观感因此连续（owner 要的「不先跳一下」）。
    ///
    /// 非 private：点击翻页的落位也走这一个函数（见 `ReaderView+TapTurn.swift` 的 `turnPage`）
    /// —— 位移路径与「章尾 / 章首怎么翻」只此一处定义，与 `usesPanTurning` 同一处理。
    func settlePan(
        _ turn: PagePanTurn,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) {
        let panning = usesPanTurning(viewStore)
        switch turn {
        case .none:
            break
        case .next:
            // 判 `.next` 时 `turn` 用的是同一次手势里的 pageIndex / pageCount，
            // 所以「当前页是不是最后一页」在这里是同一个判据：是 ⇒ 换章，否则章内翻页。
            if viewStore.currentPageIndex == viewStore.pages.count - 1 {
                viewStore.send(.advanceChapter)
            } else {
                viewStore.send(.nextPage)
            }
            if panning {
                slideOffset += availableWidth
            }
        case .previous:
            // 镜像 `.next`：判 `.previous` 时用的是同一次手势里的 pageIndex，
            // 所以「当前页是不是第一页」在这里是同一个判据：是 ⇒ 退章，否则章内翻页。
            if viewStore.currentPageIndex == 0 {
                viewStore.send(.retreatChapter)
            } else {
                viewStore.send(.prevPage)
            }
            if panning {
                slideOffset -= availableWidth
            }
        }
        // 不走平移时 `slideOffset` 恒为 0（Reduce Motion 不跟手），这句是空操作。
        withAnimation(slideSettleAnimation()) {
            slideOffset = 0
        }
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
    ///
    /// 非 private：点击翻页的位移要跟它**同一条曲线、同一个时长**（见
    /// `ReaderView+TapTurn.swift` 的 `singlePage`），时长与曲线只留这一处定义。
    func slideSettleAnimation() -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    }

    // 中央点击的判定已随点击手势的回调一起搬到 `ReaderView+TapTurn.swift` 的
    // `tapTurnZone`（它同时判左 / 中 / 右三个分区）。边界条件与这里原`isCenterTap`
    // 逐字相同（`width / 3`、`width * 2 / 3`），中央 1/3 的行为没有变。
}

// MARK: - 控制栏显隐的兜底点击

/// 控制栏显隐的**兜底点击层**（挂在 `ReaderView.body` 的正文 `ZStack` 上）。
///
/// ## 为什么需要
/// 正文还没排出来时，`readerContent` 走的是占位分支、**不经过 `pageContent`**
/// ⇒ 上面那条 `readerGesture` 根本没挂上，整屏点击无处可去。换章 / 开章的网络
/// 等待里因此点不出上下栏，也就按不到「返回」退出书本。
///
/// ## 只在「加载中且无正文」时生效
/// 判据与 `readerContent` 的**加载**分支逐字对应（`isLoading` 且 `text` 为空）。
/// ⛔ **加载失败态不由本层兜底**：那个分支页面上有「重试」按钮，而本层是它的祖先
/// —— 点按钮时两层可能同发（重试的同时把上下栏也切了）；失败态改由页面自己垫在
/// `ContentUnavailableView` **之下**的点击层接管（见 `readerContent` 的失败分支）。
/// 正文排出来后 `guard` 挡住：中央点击仍由正文层自己的 `SpatialTapGesture` 负责。
///
/// ## 为什么只挂点击、不挂拖拽
/// 占位状态下没有任何可翻的页：挂拖拽只会把 `trackSlide` / `slideBaseline` 这些
/// 跟手状态在空 `pages` 上写脏。平移翻页的手势口径因此一字未改。
///
/// 覆盖**整屏**（含正文盒之外的上 / 下边距，`PageInset()` 默认 78 / 30）：加载中
/// 要按的「返回」就在屏幕顶部，而它并不在正文盒里。
///
/// ⚠️ 必须是 `extension View` 而不是 `extension ReaderView`：调用点是链式的
/// `.chromeToggleTapFallback(...)` 挂在正文 `ZStack` 上，成员查找按**接收者的类型**
/// （`ZStack`）走 —— 写在 `ReaderView` 上会报 `has no member`（CI 实测）。
extension View {
    func chromeToggleTapFallback(
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        onToggle: @escaping () -> Void
    ) -> some View {
        onTapGesture {
            guard viewStore.isLoading, viewStore.text.isEmpty else { return }
            onToggle()
        }
    }
}
