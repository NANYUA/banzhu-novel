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
/// - **焦点 / 键盘工具栏**：本控件**不自己**声明 `@FocusState`，而是接设置页传进来的
///   `focus`（`FocusState<String?>.Binding`），行身份 = `title`。键盘工具栏「完成」因此
///   **全页只有一处**（在 `ReaderSettingsView`）—— 改造前每行各挂一份，10 份堆叠：
///   既冒出 10 个「完成」，聚焦时装配 10 份工具栏也是「打开输入框调边距很卡」的根因。
/// - **宽度**：数字框是**固定宽度**（算式见 `NumberInputMetrics.fieldWidthBase`）。
///   改造前写的是 `minWidth` ⇒ 它在 `HStack` 里是**弹性**的、会被 `Spacer` 拉开，
///   同一页各行宽度因此各不相同（owner 反馈第 1 条）。
///
/// ## 复用的既有实现（不另造观感；尺度常量只收在本控件自己的 metrics 里）
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

    /// 页面级焦点绑定（由 `ReaderSettingsView` 的 `@FocusState<String?>` 传入）。
    /// 行身份用 `title`：全页 11 处标题互不相同 ⇒ 不必另立一套 id 枚举。
    let focus: FocusState<String?>.Binding

    /// 本行正在编辑吗 —— 由**页面焦点派生**，而不是行自己再存一份 `@FocusState`
    /// （同一个框挂两个 `.focused` 只有一个生效 ⇒ 焦点只能有一个真相源）。
    /// 焦点移走、或工具栏「完成」把焦点置 `nil` 时它变 `false` ⇒ 下面的
    /// `.onChange(of: isEditing)` 触发提交；草稿的装载 / 提交时机与改造前逐值不变。
    private var isEditing: Bool {
        focus.wrappedValue == title
    }

    /// 数字框宽度：基础值（算式见 `NumberInputMetrics.fieldWidthBase`）随 `.body` 字号缩放
    /// —— 先例 `DownloadSummaryCard.progressColumnWidth`。钉死基础值的话，
    /// 大字号下框里那 4 位数字会被裁掉。
    @ScaledMetric(relativeTo: .body) private var fieldWidth = NumberInputMetrics.fieldWidthBase

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
            // 固定宽度（算式见 `NumberInputMetrics.fieldWidthBase`）：⛔ 不是 `minWidth` ——
            // 弹性宽度会被行首的 `Spacer` 拉开，同一页各行宽度就各不相同（owner 反馈第 1 条）。
            .frame(width: fieldWidth)
            // `frame` 没有「固定 `width` + `minHeight`」的重载，故分两步补上命中区下限
            // （44pt = `minTouchTarget`，与改造前同值；宽度本身已 ≥ 44）。
            .frame(minHeight: ReaderChromeMetrics.minTouchTarget)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xs)
                    .fill(AppTheme.Surface.inset)
            }
            .focused(focus, equals: title)
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

// MARK: - 尺度常量

/// `NumberInputRow` 专有的尺度常量（通用间距 / 圆角仍取 `DesignTokens`）。
///
/// 沿用 `DownloadCardMetrics` / `ReaderChromeMetrics` 的先例：控件专有尺寸收在控件自己的
/// metrics 里，`DesignTokens` 只放通用刻度。
///
/// ⚠️ 数字框宽度是**全页 11 行的唯一来源**（控件内部一处常量）—— 各行不再各写各的。
private enum NumberInputMetrics {
    /// 框里**最宽**的值占几个等宽数字位。取全页最宽的那个值：
    /// 「字间距」下限 `-1`（步长 `0.5` ⇒ 按 `%.1f` 显示成 **`-1.0`**）⇒ **4 位**。
    /// ⚠️ **不是**「上边距」的 `200`（3 位）—— 那是全页最宽的**整数**值，带小数的那一行比它宽。
    static let fieldGlyphCount: CGFloat = 4

    /// 本控件所在行的字号 **17pt**：`ReadingFontFactory` 建字体用的
    /// `PaginationConfiguration.fontSize` 默认值，也是 `Form` 行里 `.body` 文本样式在
    /// **默认内容尺寸**下的大小（本控件不写固定字号 —— 全仓不用固定字号，见 `ReaderChromeMetrics.iconFont`）。
    static let fieldFontSize: CGFloat = 17

    /// SF Pro **等宽数字**（tabular figures，`.monospacedDigit()`）的字宽 ≈ **0.6 em**
    /// （1229 / 2048，与 `ReaderChromeMetrics.chevronOpticalScale` 同一套 unitsPerEm 口径）。
    /// ⚠️ Apple 未公开该比值 ⇒ 与那个 `chevronOpticalScale` 一样是**估算值**；
    /// 真机上若仍挤，**只改这一个数**。
    static let tabularDigitAdvanceRatio: CGFloat = 0.6

    /// 数字框的**固定宽度**（`@ScaledMetric` 的基础值，随 `.body` 字号一起缩放）。
    ///
    /// ## 算式（⛔ 不是凭感觉拍的数）
    /// - 文本宽 = 4 位 × 17pt × 0.6 em = **40.8pt**；
    /// - 左右内边距 = `DesignTokens.Spacing.xxs`(4) × 2 = **8pt**（控件里既有的 `.padding`，未改）；
    /// - ⇒ 4 × 17 × 0.6 + 2 × 4 = **48.8pt**；
    /// - 再与触控目标下限 `ReaderChromeMetrics.minTouchTarget`(44) 取大 ⇒ **48.8pt**
    ///   （44 只在字宽估算偏得离谱时才兜底，但这条下限必须显式写着）。
    ///
    /// `-` 与 `.` 的字宽都小于数字（≈0.33 / 0.27 em）⇒ 按「4 个数字」算是**上界**。
    /// 落到框里（文本区 = 48.8 − 2 × 4 = **40.8pt**）：
    /// - 三位数 `200`（3 位 = 30.6pt）⇒ 左右各余 **5.1pt**，不拥挤（owner 要的正是这一档）；
    /// - 一位小数 `0.5` / `1.5`（3 位）同上；
    /// - 4 位的 `-1.0`（「字间距」下限）恰好铺满 —— 若真机上仍被切边，
    ///   **只调 `tabularDigitAdvanceRatio` 这一个数**，不要去改 11 处的调用点。
    static let fieldWidthBase: CGFloat = max(
        ReaderChromeMetrics.minTouchTarget,
        fieldGlyphCount * fieldFontSize * tabularDigitAdvanceRatio + 2 * DesignTokens.Spacing.xxs
    )
}
