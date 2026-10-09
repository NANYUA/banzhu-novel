import SwiftUI

/// 卡片 / 胶囊类可点元素的按压反馈。
///
/// ## 为什么需要它
/// 自定义卡片用 `.buttonStyle(.plain)` 时没有任何按下反馈，用户点下去要等跳转才知道点到了。
/// Apple HIG 要求**按下瞬间**就给反馈，而不是等抬手。
///
/// ## 设计取值
/// - 按下：轻微缩小 + 略微变暗；抬手复原。
/// - 时长 0.12s、`easeOut`，属于克制反馈，不做弹跳（弹跳只留给有惯性输入的拖拽）。
/// - 只动 `scale` 与 `opacity`，走合成器，不掉帧。
/// - 「减弱动态效果」开启时不做缩放，退化为纯透明度变化（HIG 的无前庭刺激等价反馈）。
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
                    .easeOut(duration: reduceMotion ? 0.08 : 0.12),
                    value: configuration.isPressed
                )
        }
    }
}
