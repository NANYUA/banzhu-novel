import Foundation
import SwiftUI

/// 阅读设置里的**数值输入行**：`[标题] …… [−] [数字框] [+]`（owner 2026-10-11 口径）。
///
/// ## 为什么替换掉 `Slider`
/// 滑杆只能拖、落不到精确值。本控件同时给两条路：点 `−` / `+` 按**步长**微调（长按连续变化），
/// 或直接在数字框里**键入**。
///
/// ## 行为口径（阅读设置页 10 处调用点共用这一份实现，不各自写）
/// - **步进**：`± step`，先夹取到 `range`、再吸附到 `range.lowerBound + n × step`
///   （「字间距」的 `0.5` 步长同样按此走）。
/// - **键入的提交时机**：键盘 return / 失焦（键盘工具栏的「完成」也是失焦）。
///   ⛔ **不是**每敲一个字符 —— 否则 `1` → `12` → `128` 这类中间态都会被写进设置。
/// - **非法输入**（空 / 非数字 / 多个小数点 / 非有限值）⇒ 还原为当前值：**不写设置、不崩**。
/// - **端点**：到 `range` 两端时对应按钮 `.disabled(true)` + 置灰 —— 用禁用态表达「到极限了」，
///   比另写一行范围提示省空间。
/// - **显示**：整数步长不带小数；带小数的步长保留一位（`1.5`）。
/// - **键盘**：整数步长 `.numberPad`，带小数步长 `.decimalPad`（小数键盘才有小数点键）。
///
/// ## 复用的既有实现（不另造观感、不新增尺度常量）
/// - 44pt 命中区 / 图标字体 / `contentShape` / 无障碍标签：`chromeIconLabel`（唯一构建处）；
/// - 按下反馈：`ReaderChromeMetrics.buttonStyle`（`PressableCardButtonStyle`，44pt 按钮那一档）；
/// - 到端点置灰：`ReaderChromeMetrics.disabledOpacity`（自定义 `ButtonStyle` 不会自动降级外观）；
/// - 间距 / 圆角 / 数字框底色：`DesignTokens` / `AppTheme`，不写魔数、不写色值。
struct NumberInputRow: View {
    /// 行标题（左对齐）。两个按钮的无障碍语义由它派生（「减小 / 增大 <标题>」）。
    let title: String

    /// 读写目标 —— 写回即交给调用方的绑定（阅读设置页里就是 `PaginationConfiguration`）。
    @Binding var value: CGFloat

    /// 允许范围（闭区间）。
    let range: ClosedRange<CGFloat>

    /// 步长（`0.5` ⇒ 允许一位小数）。
    let step: CGFloat

    /// 编辑中的草稿。`nil` = 不在编辑 ⇒ 框里显示当前值的格式化结果。
    ///
    /// 键入**只写这里**、不写 `value`：提交时机是 return / 失焦（见类型注释）。
    @State private var draft: String?

    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title)
            Spacer(minLength: DesignTokens.Spacing.sm)
            stepButton(
                systemImage: "minus",
                label: "减小 \(title)",
                delta: -step,
                isAtLimit: value <= range.lowerBound
            )
            valueField
            stepButton(
                systemImage: "plus",
                label: "增大 \(title)",
                delta: step,
                isAtLimit: value >= range.upperBound
            )
        }
    }

    /// 数字框：居中、等宽数字、可键入。底色是 `AppTheme.Surface.inset`（卡面内再嵌一层的语义色），
    /// 让它一眼读得出「这里能改」；命中区与两个按钮一样取 44pt。
    private var valueField: some View {
        TextField("", text: draftBinding)
            .keyboardType(hasFractionalStep ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .padding(.horizontal, DesignTokens.Spacing.xxs)
            .frame(
                minWidth: ReaderChromeMetrics.minTouchTarget,
                minHeight: ReaderChromeMetrics.minTouchTarget
            )
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xs)
                    .fill(AppTheme.Surface.inset)
            }
            .focused($isEditing)
            .onSubmit(commit)
            .onChange(of: isEditing) { _, editing in
                // 进入编辑时把当前值灌进草稿（此后框里的内容只由草稿决定）；
                // 失焦即提交 —— 这是「不每敲一个字符就写设置」的那一半。
                if editing {
                    draft = formattedValue
                } else {
                    commit()
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(formattedValue)
            .toolbar {
                // `.numberPad` / `.decimalPad` **没有 return 键**，失焦是唯一的提交路径
                // ⇒ 键盘上必须给一个「完成」把它变得可达。
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isEditing = false }
                }
            }
    }

    /// 一个 `−` / `+` 按钮：44pt 命中区 + 按下反馈（复用栏内按钮那套）+ 到端点置灰。
    ///
    /// `buttonRepeatBehavior(.enabled)` = 按住不放时**连续**按步长变化（iOS 17 的按钮重复行为）。
    /// 不用自己起定时器：也就不会出现「抬手后定时器还在跑」这类需要额外收尾的状态。
    private func stepButton(
        systemImage: String,
        label: String,
        delta: CGFloat,
        isAtLimit: Bool
    ) -> some View {
        Button {
            adjust(by: delta)
        } label: {
            chromeIconLabel(systemImage, a11yLabel: label)
        }
        .buttonStyle(ReaderChromeMetrics.buttonStyle)
        .buttonRepeatBehavior(.enabled)
        .disabled(isAtLimit)
        .opacity(isAtLimit ? ReaderChromeMetrics.disabledOpacity : 1)
    }

    /// 框的文本绑定：读 = 草稿（没有草稿时给当前值的格式化结果），写 = **只写草稿**。
    private var draftBinding: Binding<String> {
        Binding(
            get: { draft ?? formattedValue },
            set: { draft = $0 }
        )
    }

    /// 步长带小数吗（阅读设置页里只有「字间距」是 `0.5`）。决定键盘类型与显示位数。
    private var hasFractionalStep: Bool {
        step.truncatingRemainder(dividingBy: 1) != 0
    }

    /// 框里显示的值：整数步长不带小数；带小数的步长保留一位（`1.5`）。
    private var formattedValue: String {
        hasFractionalStep
            ? String(format: "%.1f", value)
            : String(Int(value.rounded()))
    }

    /// 草稿解析出的合法值（没在编辑 / 非法输入 ⇒ `nil`）。
    ///
    /// `Double(_:)` 对空串、非数字、多个小数点（`1.2.3`）都返回 `nil`；
    /// 额外的 `isFinite` 只挡 `nan` / `inf` —— 它们能通过 `Double(_:)`，
    /// 而且 NaN 参与 `min` / `max` 的比较会原样穿过夹取、把设置写坏。
    private var committedDraft: CGFloat? {
        guard let text = draft?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard let parsed = Double(text), parsed.isFinite else { return nil }
        return CGFloat(parsed)
    }

    /// 按步长走一格：基准是**已提交的值**（框里有合法草稿时先用它，非法草稿则退回当前值）。
    private func adjust(by delta: CGFloat) {
        let base = committedDraft ?? value
        draft = nil
        apply(base + delta)
    }

    /// 提交草稿：合法 ⇒ 夹取 + 吸附后写设置；非法 ⇒ 只丢掉草稿（框里自动回到当前值）。
    private func commit() {
        let parsed = committedDraft
        draft = nil
        guard let parsed else { return }
        apply(parsed)
    }

    /// 夹取到 `range` 并吸附到步长网格：`range.lowerBound + n × step`。
    ///
    /// 吸附**相对下限**做（而不是相对 0），这样下限不是步长整数倍的区间也不会漂。
    private func apply(_ raw: CGFloat) {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        let snapped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
    }
}
