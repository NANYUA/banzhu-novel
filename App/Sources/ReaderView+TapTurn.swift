import ComposableArchitecture
import NovelCore
import SwiftUI

/// 阅读页的**点击翻页**：左 1/3 点一下退一页、右 1/3 点一下进一页。
///
/// 与滑动翻页**并存**（不是二选一）：滑动那条路一字未改，本文件只是把
/// `ReaderView+PageGesture.swift` 里那个 `SpatialTapGesture` 的**回调**从内联闭包
/// 提成一个函数，在里面多接一支「左右两侧」。中央 1/3 呼出 / 收起控制栏仍是既有那一支，
/// 判据（`width / 3` 与 `width * 2 / 3`）也一并搬进 `tapTurnZone`，**行为一字不变**
/// （见 `handleReaderTap`）。
///
/// ## 与滑动同源的两处
/// 1. **能不能翻**：判定走 `panGeometry`（与滑动**同一份** `hasNextChapterPage` /
///    `hasPreviousChapterPage`），不复制第二份章界判据 ⇒ 章尾点右 1/3 进下一章、
///    章首点左 1/3 回上一章末页，与滑动逐字一致；
/// 2. **动画**：落位走 `settlePan`（滑动松手后的同一个落位函数）⇒ 位移路径、
///    时长、曲线都只有一处定义。
///
/// ## 本文件还装了从 `ReaderView.swift` 搬来的单页渲染
/// `ReaderView.swift` 贴着 SwiftLint `file_length` 600 的线（点击翻页那两行没地方放），
/// 所以把 `singlePage` 连同它的两个依赖（`pageIdentity` / `currentPageSlice`）搬到这里
/// —— 那边是 `private extension ReaderView`，`private` 成员出了文件就不可见，必须换归属。
/// **搬动不改行为**（实现逐字未改），本文件新增的只有 `singlePage` 里那两行：
/// `.offset(x: slideOffset)` 与它下面的 `.animation(…, value: slideOffset)`。
extension ReaderView {
    /// 点击分区。三等分沿用的坐标系与改动前的 `isCenterTap` **完全一致**（见 `tapTurnZone`）。
    private enum PageTapZone {
        case previous
        case center
        case next
    }

    /// 阅读页那**唯一**的点击手势的回调：中央 1/3 交给既有行为，左右两侧走点击翻页。
    ///
    /// 中央那一支与改前**逐字一致**（同一条边界、同一个 `onCenterTap()`），
    /// 改动只影响左右两侧 —— 两个分区在 `tapTurnZone` 里用的边界就是改动前
    /// `isCenterTap` 那两条（`width / 3` 与 `width * 2 / 3`），所以中央区不会漂移。
    func handleReaderTap(
        _ locationX: CGFloat,
        width: CGFloat,
        onCenterTap: @escaping () -> Void
    ) {
        switch tapTurnZone(locationX, width: width) {
        case .center:
            onCenterTap()
        case .previous, .next:
            turnPage(at: locationX, width: width)
        }
    }

    /// 点击落点：左 1/3 退一页、右 1/3 进一页、中央 1/3 交给既有那支手势。
    ///
    /// 边界与改动前的 `isCenterTap` **逐字对齐**（`locationX >= width / 3 &&
    /// locationX <= width * 2 / 3` 才是中央）：所以这里左支用 `<`、右支用 `>`，
    /// 两条边界点（`width / 3`、`width * 2 / 3`）仍归中央 ⇒ 中央 1/3 一个像素都没少。
    ///
    /// ⚠️ `locationX` 是**正文盒**内的 x，不是整屏宽：正文层被 `.frame(width:)` 钉到
    /// `availableWidth`（= 全屏宽 − 左右安全区，见 `readerContentSize`），而左右安全区
    /// 是挂在这一层**外面**的 `.padding` ⇒ 手势的坐标系就是正文盒。改动前的 `isCenterTap`
    /// 喂的也是同一个 `availableWidth`，两侧判据因此共用一条边界、不会漂移。
    private func tapTurnZone(_ locationX: CGFloat, width: CGFloat) -> PageTapZone {
        if locationX < width / 3 {
            return .previous
        }
        if locationX > width * 2 / 3 {
            return .next
        }
        return .center
    }

    /// 点击翻页的落位：判据与滑动**同一份几何**，落位与滑动**同一个函数**。
    ///
    /// 边界不另判：`panGeometry` 给的 `pageIndex` / `pageCount` /
    /// `has*ChapterPage` 已经编码了「全书第一页点左侧」「全书最后一页点右侧」
    /// —— 前者 `pageIndex == 0` 且没有上一章页 ⇒ 不翻；后者 `pageIndex == pageCount - 1`
    /// 且没有下一章页 ⇒ 不翻。两条都是静默无反应（`pages` 为空时 `currentPageIndex`
    /// 是 `-1`，同样两条都不成立）。
    private func turnPage(at locationX: CGFloat, width: CGFloat) {
        let geometry = panGeometry(viewStore, availableWidth: width)
        let turn: PagePanTurn
        switch tapTurnZone(locationX, width: width) {
        case .center:
            return
        case .previous:
            guard geometry.pageIndex > 0 || geometry.hasPreviousChapterPage else { return }
            turn = .previous
        case .next:
            guard geometry.pageIndex + 1 < geometry.pageCount || geometry.hasNextChapterPage else {
                return
            }
            turn = .next
        }
        settlePan(turn, viewStore: viewStore, availableWidth: width)
    }

    // MARK: - 单页渲染（点击翻页的位移落点）

    /// 单页渲染：平移不可用（Reduce Motion、未分页）时的兜底，也是点击翻页位移的落点。
    ///
    /// 从 `ReaderView.swift` 搬来的（那个文件贴着 SwiftLint `file_length` 600 的线，
    /// 点击翻页的净增行由这次搬动抵消）；搬动不改行为，唯一新增的是 `.offset` 与它下面
    /// 那行 `.animation` —— 两条合起来才是「页码变」与「位移」在同一次连续动画里完成：
    /// - `.offset(x: slideOffset)`：点击翻页先由 `settlePan` 把偏移补上一页，动画归零后
    ///   新页此刻的屏幕位置**完全没变**（与平移翻页同一条位移路径）；
    /// - `.animation(…, value: slideOffset)`：`usesPan` 为真时挂 `nil`（那条路自己带
    ///   动画，见 `panPages`，叠上来会打架）；为假时挂 `slideSettleAnimation()`
    ///   —— 与平移翻页的吸附回位**同一条曲线、同一个时长**。Reduce Motion 下 `settlePan`
    ///   不动偏移（它按「能不能跟手」判），退化由 `pageAnimation()` 那条淡入淡出负责。
    @ViewBuilder
    func singlePage(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        configuration: PaginationConfiguration,
        usesPan: Bool
    ) -> some View {
        let slice = currentPageSlice(viewStore)
        PageTextView(
            text: slice.text,
            configuration: configuration,
            startsAtParagraphStart: slice.startsAtParagraphStart
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 正文永远不接受命中测试：手势统一挂在外层（`slideGesture`），
        // 否则 `UITextView` 会把拖拽吞掉（原先只有滚动方式才打开命中测试，滚动已删）。
        .allowsHitTesting(false)
        .offset(x: slideOffset)
        .animation(usesPan ? nil : slideSettleAnimation(), value: slideOffset)
        .id(pageIdentity(viewStore))
        .transition(pageTransition())
    }

    // MARK: - 单页渲染的两个依赖（从 `ReaderView.swift` 搬来，实现一字未改）

    /// 页面身份 = **章节路径 + 页码**：换章时身份必须变化，否则章尾无缝进下一章若停在
    /// `0 → 0`（旧章只有 1 页），Reduce Motion 的单页 `.opacity` 转场就不会播（内容会换但像硬切）。
    func pageIdentity(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        "\(viewStore.chapterPath)-\(viewStore.currentPageIndex)"
    }

    /// 取当前页对应的文本片段 + 「本页是否从段落开头开始」（首行缩进的判据）。
    ///
    /// 判据只此一处：调 NovelCore 的 `ParagraphBoundary`，度量侧 `TextKitMeasuring` 用的是同一条。
    func currentPageSlice(
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
