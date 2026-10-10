import ComposableArchitecture
import NovelCore
import SwiftUI

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
            panPage(text: slot.text, configuration: viewStore.config)
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
    private func panSlots(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> [PanSlot] {
        let current = viewStore.currentPageIndex
        let pages = viewStore.pages
        return [-1, 0, 1].compactMap { relative in
            let index = current + relative
            if pages.indices.contains(index) {
                return PanSlot(
                    id: PanSlot.Identity(path: viewStore.chapterPath, index: index),
                    text: pageText(at: index, in: pages, text: viewStore.displayText),
                    relativeIndex: relative
                )
            }
            guard relative == 1, !pages.isEmpty, current == pages.count - 1,
                  !viewStore.nextPages.isEmpty
            else { return nil }
            return PanSlot(
                id: PanSlot.Identity(path: viewStore.nextChapter?.path ?? "", index: 0),
                text: pageText(at: 0, in: viewStore.nextPages, text: viewStore.nextDisplayText),
                relativeIndex: 1
            )
        }
    }

    /// 全景图里的一格。**不接受命中测试**：手势挂在外面那层（见 `slideGesture`）。
    private func panPage(
        text: String,
        configuration: PaginationConfiguration
    ) -> some View {
        PageTextView(text: text, configuration: configuration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    /// 指定页的文本片段（与 `currentPageText` 的区别：越界返回空串，不做「整章兜底」）。
    ///
    /// 文本**显式传入**：当前章（`displayText`）与预加载的下一章（`nextDisplayText`）
    /// 共用这一份切片逻辑，不复制第二份。
    private func pageText(at pageIndex: Int, in pages: [PageRange], text: String) -> String {
        guard pages.indices.contains(pageIndex), !text.isEmpty else { return "" }
        let page = pages[pageIndex]
        let chars = Array(text)
        let start = min(page.location, chars.count)
        let end = min(page.location + page.length, chars.count)
        guard start < end else { return "" }
        return String(chars[start ..< end])
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
                        if isCenterTap(value.location.x, width: availableWidth) {
                            onCenterTap()
                        }
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
        // 基线只在本次手势的第一次 onChanged 采一次：之后 translation 是
        // 相对同一个起点累积的，逐帧重采就会把已跟手走的位移当成新基线而滚雪球。
        let baseline = slideBaseline ?? slidePresentation.offset
        slideBaseline = baseline
        slideOffset = panOffset(
            from: baseline,
            translation: value.translation.width,
            viewStore: viewStore,
            availableWidth: availableWidth
        )
    }

    /// 抬手：判页 + 落位。
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
        let turn = PagePanTracking.turn(
            trackedOffset: panOffset(
                from: baseline,
                translation: value.translation.width,
                viewStore: viewStore,
                availableWidth: availableWidth
            ),
            translation: value.translation.width,
            predictedEndTranslation: value.predictedEndTranslation.width,
            geometry: PagePanGeometry(
                availableWidth: availableWidth,
                pageIndex: viewStore.currentPageIndex,
                pageCount: viewStore.pages.count,
                // 下一章第 1 页已就绪 ⇒ 本章最后一页仍可继续 `.next`（换章）。
                hasNextChapterPage: !viewStore.nextPages.isEmpty
            )
        )
        settlePan(turn, viewStore: viewStore, availableWidth: availableWidth)
    }

    /// 跟手位移：纯数学在 `PagePanTracking`，这里只负责把 `@State` 递进去。
    private func panOffset(
        from baseline: CGFloat,
        translation: CGFloat,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) -> CGFloat {
        PagePanTracking.panOffset(
            fromDisplayedOffset: baseline,
            translation: translation,
            availableWidth: availableWidth,
            pageIndex: viewStore.currentPageIndex,
            pageCount: viewStore.pages.count
        )
    }

    /// 松手落位：翻页就把平移**走完**，不翻页就滑回本页。
    ///
    /// 翻页那一支先把偏移补上一页再动画归零：换页之后「新的当前页」就是原来摆在旁边那一页，
    /// 补一页后它**此刻的屏幕位置完全没变**，接着的动画是连续的平移，不是「先跳一下再滑」。
    /// 这也是「像全景图滑动，但停留在正文页」的落地点 —— 全程只走一页，不连续滚动。
    ///
    /// **章尾换章走的是同一条路**：此刻 `+1` 格上摆的就是下一章第 1 页，换章后它正好
    /// 变成当前页 —— 补位那一步与章内翻页**逐值相同**，观感因此连续（owner 要的「不先跳一下」）。
    private func settlePan(
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
            viewStore.send(.prevPage)
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
    private func slideSettleAnimation() -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    }

    // MARK: - 中央点击判定

    /// 屏幕中间三分之一算「中央点击」（呼出 / 收起控制栏），左右两侧留给翻页。
    private func isCenterTap(_ locationX: CGFloat, width: CGFloat) -> Bool {
        locationX >= width / 3 && locationX <= width * 2 / 3
    }
}
