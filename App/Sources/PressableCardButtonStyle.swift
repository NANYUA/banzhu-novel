import SwiftUI

/// 卡片 / 胶囊类可点元素的按压反馈。
///
/// ## 为什么需要它
/// 自定义卡片用 `.buttonStyle(.plain)` 时没有任何按下反馈，用户点下去要等跳转才知道点到了。
/// Apple HIG 要求**按下瞬间**就给反馈，而不是等抬手；而且这条反馈必须**可感知**——
/// 弱到看不见的反馈等于没有反馈。本样式原来只做 `scaleEffect(0.98)` + `opacity(0.88)`，
/// 在白卡上几乎看不出来（只改卡片透明度，浅色下只会冲淡文字，读起来像禁用态，不像按下）。
///
/// ## 设计取值（U1-1：页面底 = 分组灰、卡面 = 白）
/// - 按下：**touch-down 瞬间**叠一层**可见**的强调层（`Color.primary.opacity(0.12)`）+ 轻微缩小；抬手复原。
/// - 强调层用 `Color.primary` 而不是硬编码灰：浅色模式下它是黑（压暗白卡），
///   深色模式下它是白（提亮深色卡），两种外观下都有可感知的对比。
/// - ⚠️ 上面这条默认值成立的前提是「元素底色与 `Color.primary` **不同色**」。
///   底色本身就是纯白 / 纯黑时（阅读背景色块正是这种情形），`Color.primary` 会与底色同色，
///   **任何不透明度都叠不出来**；那种调用点用 `pressedHighlightColor` 传反色语义色，
///   不要改动这里的默认值。
/// - 强度 0.12 ≈ 系统 `systemFill` 量级：浅色下白卡 `#FFFFFF` → `#E0E0E0`，
///   一眼能看出「按下了」，又不至于像禁用态；也正好落在 HIG 允许的 0.10–0.15 区间内。
/// - `shape` 只用来把强调层贴齐元素自身轮廓，否则按下瞬间会在圆角 / 胶囊外露出方角。
/// - **进入 / 退出两条曲线**，两条都是临界阻尼弹簧（`dampingFraction: 1`，无回弹），不用固定时长缓动：
///   - **进入**（touch-down）用 `response: 0.05`。原来的 `response: 0.2` 上升沿太慢：
///     快速点击（约 0.1s 抬手）时强调层只到 α≈0.056（50ms）/ 0.099（100ms），
///     50ms 那个点正卡在「低于 0.08 就看不见」的门槛之下，观感就成了「只有长按有反馈」
///     （长按 0.5s 才跑满 0.12）。`response: 0.05` 约 18ms 就跨过 0.08、50ms 到位（α≈0.118），
///     touch-down 后一帧内即可感知。
///   - **退出**（抬手复原）保持原来的 `response: 0.2`（减弱动态效果时 0.1），手感逐字不变。
///   - 两条都是弹簧而非固定时长缓动：可被打断、从当前值出发，手指半途移开也不会跳变；
///     弹性只留给有惯性输入的拖拽。
/// - 只动 `scale` 与强调层的不透明度，走合成器，不掉帧。
/// - 「减弱动态效果」开启时不做缩放，**保留**强调层（HIG 的无前庭刺激等价反馈）。
///
/// ## 基线
/// iOS 18 的材质与控件体系；**不使用** iOS 26 的液态玻璃材质。
struct PressableCardButtonStyle: ButtonStyle {
    /// 按下时的缩放比例。卡片越大，幅度越小，避免整屏晃动。
    var pressedScale: CGFloat = 0.98

    /// 按下强调层贴合的轮廓。
    /// 默认矩形（永远落在元素自己的边界内）；圆角卡片传
    /// `AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))`（卡片圆角 12），
    /// 胶囊传 `AnyShape(Capsule())`。
    var shape = AnyShape(Rectangle())

    /// 按下强调层的不透明度。按下瞬间就到达这个值，所以它就是**峰值**强度；
    /// 低于约 0.08 就开始「看不见」了，别调太小。
    var pressedHighlightOpacity: Double = 0.12

    /// 按下强调层的颜色。默认 `Color.primary` —— 既有调用点（书卡行、分组 / 分类胶囊、
    /// 通知关闭按钮）的**强调层颜色**与改造前**逐字不变**（本轮只改了进入方向的曲线快慢，
    /// 颜色、`shape`、命中区、缩放幅度都没动）。
    ///
    /// 只有当元素**自身底色**可能与 `Color.primary` 同色时才需要传别的语义色
    /// （纯白 / 纯黑色块在相反外观下就是这种情形）：同色叠加时，不透明度调到多少都看不见。
    /// 传值请用语义色（`Color.primary` / `Color(.systemBackground)` 等），不写死色值。
    var pressedHighlightColor: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(
            configuration: configuration,
            pressedScale: pressedScale,
            shape: shape,
            highlightOpacity: pressedHighlightOpacity,
            highlightColor: pressedHighlightColor
        )
    }

    private struct PressableLabel: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        let shape: AnyShape
        let highlightOpacity: Double
        let highlightColor: Color

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var isPressed: Bool {
            configuration.isPressed
        }

        var body: some View {
            configuration.label
                .overlay {
                    shape.fill(highlightColor.opacity(isPressed ? highlightOpacity : 0))
                }
                .scaleEffect(reduceMotion || !isPressed ? 1 : pressedScale)
                .animation(pressAnimation, value: isPressed)
        }

        /// 按下（进入）与抬手（退出）各一条临界阻尼弹簧曲线，见类型注释。
        /// 进入用 0.05：约 18ms 跨过 0.08 的可感知阈值、50ms 到位；退出保持原来的 0.2（减弱动态效果时 0.1）。
        private var pressAnimation: Animation {
            isPressed
                ? .spring(response: 0.05, dampingFraction: 1)
                : .spring(response: reduceMotion ? 0.1 : 0.2, dampingFraction: 1)
        }
    }
}
