import CoreGraphics

/// 阅读页「滑动翻页」的跟手位移（纯数学，CI 可测）。
///
/// ## 为什么单独抽出来
/// `ReaderView.slideGesture` 在手指移动时每秒要把偏移写进 SwiftUI 五六十次，
/// 而这段算法有两个分支（1:1 跟手 / 边界橡皮筋）和一个易错点：**基线在哪个坐标系里**。
/// 它原来活在 View 的手势闭包与 `@State` 之间，全仓零测试 —— 算错了只有真机手感能发现。
/// 抽成纯函数后，「基线为 0 时与改动前逐值一致」这条回归保证才由 CI 兜住
/// （先例：`TextCursor`、`ChapterDownloadSelection`）。
///
/// ⚠️ 只依赖 `CGFloat`（CoreGraphics），不 import SwiftUI / UIKit ——
/// `scripts/check-architecture.sh` 规则 1 禁止 `Packages/` 引用 UI 框架。
///
/// ## 背景：为什么需要「基线」
/// `DragGesture.translation.width` 是**相对本次手势起点**的，而页面偏移是
/// **相对页面静止位置**的。吸附回位动画（0.22s 缓动）跑到一半再抓手势时，
/// 页面此刻显示在（比如）35pt 处，新手势的 translation 从 0 起 ——
/// 若直接把 translation 当偏移写下去，画面会从 35pt 瞬间跳到 10pt。
/// 所以跟手量必须是「抓取瞬间**真实显示**的位置 + 本次手势位移」。
public enum SlideTracking {
    /// 边界橡皮筋的起始阻力（沿用改动前写死在 `ReaderView` 里的同一个字面量 0.55，
    /// 不是新调的参数）：起始跟手比例≈`resistance`，之后越来越钝，
    /// 渐近线是 **`availableWidth`**（一整屏宽，见 `rubberBanded`）。
    static let resistance: CGFloat = 0.55

    /// 本次手势跟手后，页面应当显示的横向偏移。
    ///
    /// 非边界时就是 `displayedOffset + translation`；边界时走橡皮筋（见下）。
    ///
    /// - Parameters:
    ///   - displayedOffset: **抓取瞬间页面真实显示**的偏移（吸附动画进行中即呈现值）。
    ///   - translation: 本次手势的 `DragGesture.Value.translation.width`。
    ///   - availableWidth: 阅读区可用宽度（安全区内的盒宽）。
    ///   - pageIndex: 当前页下标。
    ///   - pageCount: 总页数。
    /// - Returns: 页面此刻应显示的偏移。
    public static func offset(
        fromDisplayedOffset displayedOffset: CGFloat,
        translation: CGFloat,
        availableWidth: CGFloat,
        pageIndex: Int,
        pageCount: Int
    ) -> CGFloat {
        // 宽高为 0 的退化盒子：直接归零，别让橡皮筋公式算出 0/0。
        guard availableWidth > 0 else { return 0 }

        // 边界判定与改动前**逐字一致**：只看「本次手势的方向 + 当前页」，
        // 不看基线 —— 否则抓着停在别的页面上的画面会改变边界判定。
        let isAtEdge = translation > 0 ? pageIndex <= 0 : pageIndex + 1 >= pageCount
        guard isAtEdge else { return displayedOffset + translation }

        // 边界这条路也作用在**同一个量**上：先把「此刻显示的位置」还原成它对应的
        // 未压缩位移，再加上本次手势位移，最后重新压缩。
        // 这样三件事同时成立：
        //   1. 抓取瞬间（translation → 0）结果就是显示值本身 —— 不跳变；
        //   2. 结果永远有界（绝对值 < availableWidth），不会越拖越远；
        //   3. 整条路径与「从按下起就没松手」完全重合 —— 跟手与橡皮筋两条路不打架。
        //
        // 还原不出来（显示值已在橡皮筋值域之外，见 `unrestrainedOffset`）时退化成 1:1：
        // 至少「抓取瞬间不跳变」这条保住，而那种显示值本来也越过了橡皮筋能压住的范围。
        // 这个分支在正常路径上不可达，它是为「动画途中容器宽度突然变小」兜底的。
        guard let resumed = unrestrainedOffset(of: displayedOffset, availableWidth: availableWidth) else {
            return displayedOffset + translation
        }
        return rubberBanded(resumed + translation, availableWidth: availableWidth)
    }

    /// 边界橡皮筋：位移越大越钝，渐近但**永远到不了** `availableWidth`。
    ///
    /// 公式与改动前**逐字一致**（`raw * W * 0.55 / (W + 0.55 * |raw|)`），
    /// 连乘除顺序都没动 —— 这是「基线为 0 时逐值一致」那条回归测试的前提。
    /// 顺带纠正一个容易记错的量：`W * 0.55` 不是上限，`0.55` 只是**起始**斜率
    /// （`rubberBanded'(0) = 0.55`）；真正的渐近线是 `W`：
    /// `x·W·k/(W + k·|x|) < W ⟺ W² > 0`。
    static func rubberBanded(_ offset: CGFloat, availableWidth: CGFloat) -> CGFloat {
        offset * availableWidth * resistance / (availableWidth + resistance * abs(offset))
    }

    /// `rubberBanded` 的反函数：屏幕上显示 `offset` 时，它对应的未压缩位移。
    ///
    /// 由 `y = x·W·k / (W + k·|x|)` 解出 `x = y·W / (k·(W − |y|))`（与 y 同号）。
    ///
    /// ## 奇点
    /// `|y| → W` 时分母趋于 0、反函数发散。而橡皮筋的值域恰是 `(-W, W)`：
    /// `rubberBanded` 的输出**恒有** `|y| < W`（`y < W ⟺ W² > 0` 恒成立），
    /// 所以正常路径永远取不到奇点。这里仍然**显式早退**，返回 `nil` 让调用方
    /// 退回 1:1 —— 与其算出 `inf` / `nan` 或一次符号翻转的瞬移，
    /// 不如承认「这个显示值不可能是橡皮筋压出来的」。
    /// 真的碰得到它的场景只有一个：动画跑到一半容器宽度突然变小（旋转 / 分屏）。
    ///
    /// - Returns: 未压缩位移；`|offset| >= availableWidth`（含奇点）时为 `nil`。
    static func unrestrainedOffset(of offset: CGFloat, availableWidth: CGFloat) -> CGFloat? {
        guard availableWidth > 0, abs(offset) < availableWidth else { return nil }
        return offset * availableWidth / (resistance * (availableWidth - abs(offset)))
    }
}
