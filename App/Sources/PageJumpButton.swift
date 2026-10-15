import SwiftUI

/// 跳页按钮：显示当前页码，点击弹出输入框，跳到指定页码。
///
/// 书城（筛选栏右上）与搜索页（结果区顶部右对齐）共用。
/// 风格与分组胶囊按钮一致（参照 `ExploreView+CategoryBar.swift` 的 `ExploreCategoryChip`）：
/// 纯文字无符号、`.subheadline`、胶囊底、按下有反馈（`PressableCardButtonStyle`）。
struct PageJumpButton: View {
    /// 当前页码（从 1 起）。
    let page: Int
    /// 确认跳转：把目标页码交给上层发 reducer action。
    let onJump: (Int) -> Void

    @State private var isShowingInput = false
    @State private var targetText = ""

    var body: some View {
        Button {
            // 预填当前页，用户直接改数字即可。
            targetText = String(page)
            isShowingInput = true
        } label: {
            Text("第 \(page) 页")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .frame(minWidth: DesignTokens.Hit.minSize, minHeight: DesignTokens.Hit.minSize)
                .background(Capsule().fill(AppTheme.Surface.card))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Capsule())))
        .accessibilityLabel("第 \(page) 页，点击跳转页码")
        .alert("跳转页码", isPresented: $isShowingInput) {
            TextField("输入页码", text: $targetText)
                .keyboardType(.numberPad)
            Button("跳转") {
                // 非法输入（空串 / 非数字 / 小于 1）静默忽略，不跳也不报错。
                guard let target = Int(targetText.trimmingCharacters(in: .whitespaces)), target >= 1 else {
                    return
                }
                onJump(target)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前第 \(page) 页，输入要跳到的页码。")
        }
    }
}
