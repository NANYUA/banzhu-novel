import SwiftUI

/// 卡片 / 胶囊类可点元素的按压反馈。
///
/// ## 为什么需要它
/// 自定义卡片用 `.buttonStyle(.plain)` 时没有任何按下反馈，用户点下去要等跳转才知道点到了。
/// Apple HIG 要求**按下瞬间**就给反馈，而不是等抬手；而且这条反馈必须**可感知**——
/// 弱到看不见的反馈等于没有反馈。本样式原来只做 `scaleEffect(0.98)` + `opacity(0.88)`，
/// 在浅灰列表的白卡上几乎看不出来（卡片改成与页面同色后，`opacity` 更是只会冲淡文字，
/// 读起来像禁用态，不像按下）。
///
/// ## 设计取值
/// - 按下：轻微缩小 + 叠一层**可见**的强调层（`Color.primary.opacity(0.12)`）；抬手复原。
/// - 强调层用 `Color.primary` 而不是硬编码灰：浅色模式下它是黑（压暗卡片），
///   深色模式下它是白（提亮卡片），两种外观下都有可感知的对比。
/// - 强度 0.12 ≈ 系统 `systemFill` 量级：浅色下卡片 `#F2F2F7` → `#D5D5D9`，
///   一眼能看出「按下了」，又不至于像禁用态。
/// - `shape` 只用来把强调层贴齐元素自身轮廓，否则按下瞬间会在圆角 / 胶囊外露出方角。
/// - 用**临界阻尼弹簧**（`dampingFraction: 1`，无回弹）而非固定时长缓动：
///   弹簧可被打断、从当前值出发，手指半途移开也不会跳变。弹性只留给有惯性输入的拖拽。
/// - 只动 `scale` 与强调层的不透明度，走合成器，不掉帧。
/// - 「减弱动态效果」开启时不做缩放，**保留**强调层（HIG 的无前庭刺激等价反馈）。
///
/// ## 基线
/// iOS 18 的材质与控件体系；**不使用** iOS 26 的液态玻璃材质。
struct PressableCardButtonStyle: ButtonStyle {
    /// 按下时的缩放比例。卡片越大，幅度越小，避免整屏晃动。
    var pressedScale: CGFloat = 0.98

    /// 按下强调层贴合的轮廓。
    /// 默认矩形（永远落在元素自己的边界内）；圆角卡片传 `AnyShape(RoundedRectangle(cornerRadius: 8))`，
    /// 胶囊传 `AnyShape(Capsule())`。
    var shape = AnyShape(Rectangle())

    /// 按下强调层的不透明度。低于约 0.08 就开始「看不见」了，别调太小。
    var pressedHighlightOpacity: Double = 0.12

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(
            configuration: configuration,
            pressedScale: pressedScale,
            shape: shape,
            highlightOpacity: pressedHighlightOpacity
        )
    }

    private struct PressableLabel: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        let shape: AnyShape
        let highlightOpacity: Double

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var isPressed: Bool {
            configuration.isPressed
        }

        var body: some View {
            configuration.label
                .overlay {
                    shape.fill(Color.primary.opacity(isPressed ? highlightOpacity : 0))
                }
                .scaleEffect(reduceMotion || !isPressed ? 1 : pressedScale)
                .animation(
                    .spring(response: reduceMotion ? 0.1 : 0.2, dampingFraction: 1),
                    value: isPressed
                )
        }
    }
}
