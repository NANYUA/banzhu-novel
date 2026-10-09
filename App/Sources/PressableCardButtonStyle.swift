import SwiftUI

/// 卡片 / 胶囊类可点元素的按压反馈。
///
/// ## 为什么需要它
/// 自定义卡片用 `.buttonStyle(.plain)` 时没有任何按下反馈，用户点下去要等跳转才知道点到了。
/// Apple HIG 要求**按下瞬间**就给反馈，而不是等抬手。
///
/// ## 设计取值
/// - 按下：轻微缩小 + 略微变暗；抬手复原。
/// - 用**临界阻尼弹簧**（`dampingFraction: 1`，无回弹）而非固定时长缓动：
///   弹簧可被打断、从当前值出发，手指半途移开也不会跳变。弹性只留给有惯性输入的拖拽。
/// - 只动 `scale` 与 `opacity`，走合成器，不掉帧。
/// - 「减弱动态效果」开启时不做缩放，退化为纯透明度变化，并把响应压短（HIG 的无前庭刺激等价反馈）。
///
/// ## 基线
/// iOS 18 的材质与控件体系；**不使用** iOS 26 的液态玻璃材质。
struct PressableCardButtonStyle: ButtonStyle {
    /// 按下时的缩放比例。卡片越大，幅度越小，避免整屏晃动。
    var pressedScale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(configuration: configuration, pressedScale: pressedScale)
    }

    private struct PressableLabel: View {
        let configuration: Configuration
        let pressedScale: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : pressedScale)
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(
                    .spring(response: reduceMotion ? 0.1 : 0.2, dampingFraction: 1),
                    value: configuration.isPressed
                )
        }
    }
}
