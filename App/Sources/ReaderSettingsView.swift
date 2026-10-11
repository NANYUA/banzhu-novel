import Foundation
import NovelCore
import SwiftUI
import UIKit

/// 一项候选字体：Picker 显示 `displayName`，写回 `configuration.fontName` 的是 `familyName`。
private struct ReaderFontOption {
    let displayName: String
    let familyName: String
}

/// 阅读设置面板。
///
/// 面板只负责把用户选择整理成新的 `PaginationConfiguration`，
/// 通过 `onChange` 交还给 `ReaderFeature`；不直接持有业务状态。
struct ReaderSettingsView: View {
    let configuration: PaginationConfiguration
    let precacheCount: Int
    let onPrecacheCountChange: (Int) -> Void
    let onChange: (PaginationConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 当前生效的外观。自定义背景色的两个预览色卡靠它判断**哪一个算选中**
    /// （浅色外观 ↔ 亮色预览，深色外观 ↔ 暗色预览）。阅读页的「夜间模式」会经
    /// `.preferredColorScheme` 传到这个 sheet，所以这里拿到的是阅读页**实际生效**的外观，
    /// 而不是裸的系统外观。
    @Environment(\.colorScheme) private var colorScheme

    /// 当前聚焦的数值行（身份 = `NumberInputRow.title`，本页 11 处标题互不相同）。
    ///
    /// 键盘工具栏「完成」把焦点置 `nil` 即收起键盘并提交草稿 —— **全页只有这一处工具栏**
    /// （见 `body` 的 `.toolbar`）。改造前是**每一行**各挂一份（10 份堆叠）：既冒出 10 个
    /// 「完成」，聚焦时装配 10 份工具栏也正是「打开输入框调边距很卡」的根因。
    @FocusState private var focusedField: String?

    /// 字体白名单：默认系统字体（SF Pro），另给几个适合中文正文阅读的字体族。
    /// 不用 `UIFont.familyNames`，避免把 Roboto / Inter 等第三方字体灌进 Picker。
    private static let fontFamilyAllowlist: [ReaderFontOption] = [
        ReaderFontOption(displayName: "苹方（黑体）", familyName: "PingFang SC"),
        ReaderFontOption(displayName: "宋体", familyName: "Songti SC"),
        ReaderFontOption(displayName: "楷体", familyName: "Kaiti SC"),
        ReaderFontOption(displayName: "圆体", familyName: "Yuanti SC"),
        ReaderFontOption(displayName: "行楷", familyName: "Xingkai SC"),
    ]

    /// 白名单按本机可用性过滤；解析方式与 `ReadingFontFactory` 一致
    /// （先 PostScript name、再退回字族名），过滤后列表里每一项都真能渲染。
    private static let availableFontFamilies: [ReaderFontOption] = fontFamilyAllowlist.filter {
        UIFont(name: $0.familyName, size: 12) != nil
            || !UIFont.fontNames(forFamilyName: $0.familyName).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                textSection
                appearanceSection
                readingSection
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
                // 数字键盘（`.numberPad` / `.decimalPad`）**没有 return 键** ⇒ 失焦是唯一的提交
                // 路径，键盘上必须给一个「完成」。**只有这一处**：焦点置 `nil`，正在编辑的那一行
                // 由 `NumberInputRow` 的 `.onChange(of: isEditing)` 提交草稿（不是每敲一个字符就写设置）。
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
        }
    }

    // MARK: - 文字

    private var textSection: some View {
        Section("文字") {
            Picker("字体", selection: fontNameBinding) {
                Text("系统字体").tag("")
                ForEach(Self.availableFontFamilies, id: \.familyName) { option in
                    Text(option.displayName).tag(option.familyName)
                }
            }

            // 四条数值项改输入式控件（`NumberInputRow`）：可点 `−` / `+` 微调、也可直接键入。
            // 「字间距」步长 0.5 ⇒ 该控件按**带小数**处理：`.decimalPad` 键盘 + 保留一位小数
            // （旧写法 `Int(...)` 会把小数截断，显示与设置值不符）。
            NumberInputRow(title: "字号", value: binding(\.fontSize), range: 12 ... 30, step: 1, focus: $focusedField)
            NumberInputRow(title: "行距", value: binding(\.lineSpacing), range: 0 ... 20, step: 1, focus: $focusedField)
            NumberInputRow(title: "段间距", value: binding(\.paragraphSpacing), range: 0 ... 30, step: 2, focus: $focusedField)
            NumberInputRow(title: "字间距", value: binding(\.characterSpacing), range: -1 ... 5, step: 0.5, focus: $focusedField)

            Toggle("字体加粗", isOn: binding(\.isBold))
            Toggle("字体倾斜", isOn: binding(\.isItalic))
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            VStack(alignment: .leading, spacing: 10) {
                Text("背景色")
                HStack(spacing: 14) {
                    ForEach(ReadingBackgroundStyle.allCases.filter { $0 != .custom }, id: \.self) { style in
                        backgroundSwatch(style)
                    }
                }
                // 第二行：亮 / 暗两个自定义背景色色卡 —— 色卡**本身就是 `ColorPicker` 的色块**，
                // 点左卡直接开系统取色器改亮色、点右卡直接开系统取色器改暗色，各改各的。
                // 改任一个色都会自动切到「自定义」——第一行已过滤掉 `.custom`，
                // 第二行是进入自定义模式的唯一入口。
                HStack(spacing: 14) {
                    customBackgroundPicker(isLight: true)
                    customBackgroundPicker(isLight: false)
                }
            }

            Picker("文字颜色", selection: binding(\.textColorMode)) {
                ForEach(ReadingTextColorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if configuration.textColorMode == .custom {
                ColorPicker(
                    "自定义文字颜色",
                    selection: customTextColorBinding,
                    supportsOpacity: false
                )
            }

            insetSliders

            Toggle("亮度跟随系统", isOn: binding(\.followsSystemBrightness))
        }
    }

    /// 「外观」里的 6 条边距输入行（正文上 / 下 / 左右 + 标签边距 + 上标签上 / 下标签下边距）。
    ///
    /// 抽出来只为 `function_body_length`：内联在 `appearanceSection` 里会顶穿 50 行门槛
    /// （warning 即 CI 红）。`@ViewBuilder` 展开成 `TupleView` ⇒ 每一行仍是 `Section` 的
    /// **直接子视图**，`Form` 里逐行渲染的版式与内联写法逐值相同（没有多套一层容器）。
    @ViewBuilder
    private var insetSliders: some View {
        // 上下边距**拆成两个控件**（owner 2026-10-11）：语义是「距**屏幕边缘**的绝对距离」，
        // `0` = 正文贴到屏幕最边缘（**不自己适配刘海**），上 `0…200`、下 `0…120`。
        // 两个控件**各改各的**（旧实现那一个滑杆同时写 `top` 与 `bottom`，已删）。
        // 步长 2：默认 78 / 30 与两端都能精确取到（`0/30/78/120/200` 全是偶数）。
        NumberInputRow(title: "上边距", value: topInsetBinding, range: 0 ... 200, step: 2, focus: $focusedField)
        NumberInputRow(title: "下边距", value: bottomInsetBinding, range: 0 ... 120, step: 2, focus: $focusedField)
        // 左右边距（U1-8）：下限仍守 8pt、默认 24pt 由 `PageInset` 的默认值给 —— 本次未改。
        NumberInputRow(title: "左右边距", value: horizontalInsetBinding, range: 8 ... 48, step: 4, focus: $focusedField)
        // 正文边框标识（owner 2026-10-11）：打开后**阅读页**的正文盒四周出现红色虚线，
        // 标的就是「当前这三条边距下正文真正能排到的范围」。
        // 放在三条正文边距（上 / 下 / 左右）的**紧后面**：它是同一个「正文盒」主题的
        // 观测手段 —— 调完边距立刻开关一下就能看到正文盒被推到哪；离得远（比如放进「阅读」段）
        // 就要来回翻两段才能对照，失去「边调边看」的意义。
        // ⚠️ 刻意**不做**设置页内的迷你预览：正文盒的真实极限要对着刘海 / 上下栏看才有意义（owner 口径）。
        Toggle("正文边框标识", isOn: binding(\.showsTextAreaBorder))
        // 标签边距（owner 2026-10-11）：三个角落标签（左上书名 / 章节名、左下电量、右下页码）
        // **共用**这一个值，只调它们距屏幕左 / 右边缘的距离 —— 垂直位置不受它影响。
        NumberInputRow(title: "标签边距", value: hudInsetBinding, range: 0 ... 64, step: 2, focus: $focusedField)
        // 上标签 / 下标签边距（owner 2026-10-11 第二版口径）：控制栏三条面板**贴屏幕上下边**的程度。
        // 语义与正文边距一致 ——「距**屏幕边缘**的绝对距离」，`0` = 面板贴到屏幕最上 / 最下边
        // （**不避让灵动岛 / Home Indicator**，面板可以被缺口盖住 —— owner 明确要这个默认值，
        // ⛔ 别当成 bug 改回去）。
        // 范围 `0 ... 70`、默认 `0`、步长 2：`0` 就是**下限**（贴屏幕最边缘）。
        // ⚠️ 曾经允许过负值（面板移出屏幕边缘）—— owner 已改口径「不要负值」：设置页不再产出负值，
        // 老数据里的历史负值由 `mergedConfiguration` 收成 `0`。
        // 没有「自动档」（自动机制已删）：两个框各读各的设置值，`nil`（老数据缺 key）显示 0。
        NumberInputRow(title: "上标签上边距", value: topBarInsetBinding, range: 0 ... 70, step: 2, focus: $focusedField)
        NumberInputRow(title: "下标签下边距", value: bottomBarInsetBinding, range: 0 ... 70, step: 2, focus: $focusedField)
    }

    // MARK: - 阅读

    private var readingSection: some View {
        Section("阅读") {
            // 首行缩进**默认打开**（owner 口径）：开关状态单独存（`isFirstLineIndentOn`），
            // 缩进宽度由 `fontSize × 2` 派生（`PaginationConfiguration.firstLineHeadIndent`）
            // ⇒ 改字号不再需要在这里手动同步缩进值。
            Toggle("首行缩进", isOn: binding(\.isFirstLineIndentOn))

            // 预缓存章数（owner 2026-10-11）：与其余数值项**同一个控件**（可点 `−` / `+`、也可键入），
            // 不再用系统 `Stepper` —— 那样这一行的控件宽度与观感都跟其他行不一致。
            // 单位「章」写进标题：数字已经进了框里，标题必须自带单位才读得懂
            // ⇒ 控件**不需要**新增「单位后缀」参数（没有第二个调用点，别做一次性抽象）。
            // 上限取 `ReaderFeature.maxPrecacheCount`（真实上限的唯一来源，不另写 20）。
            NumberInputRow(
                title: "预缓存（章）",
                value: precacheCountBinding,
                range: 0 ... CGFloat(ReaderFeature.maxPrecacheCount),
                step: 1,
                focus: $focusedField
            )

            Picker("夜间模式", selection: binding(\.appearanceMode)) {
                ForEach(ReadingAppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 控件

    /// 预置背景色色卡（第一行）。
    private func backgroundSwatch(_ style: ReadingBackgroundStyle) -> some View {
        colorSwatch(
            color: backgroundUIColor(for: style),
            isSelected: configuration.backgroundStyle == style,
            label: style.displayName
        ) {
            var next = configuration
            next.backgroundStyle = style
            onChange(next)
        }
    }
}

private extension ReaderSettingsView {
    /// 一个背景色卡：28pt 圆 + 44pt 命中区 + 选中环 + 按下强调。
    ///
    /// 两行（预置 / 自定义）共用同一套视觉与交互 —— owner 要求自定义色卡
    /// 「使用现在的亮色背景色选项的色卡」，所以这里只把差异抽成参数，观感逐值不变。
    ///
    /// 放 extension 里：`type_body_length` 不统计 extension，而主类型 body 本就贴着门槛。
    private func colorSwatch(
        color: UIColor,
        isSelected: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(uiColor: color))
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .strokeBorder(
                            // 选中环是**品牌强调色**（与同一面板里的分段控件 / 开关同色），
                            // 不能用 `Color.accentColor` —— 它解析的是资源目录 / 系统 accent，
                            // 本项目没有 asset catalog，于是它固定是系统默认蓝，**不跟随**
                            // `RootView` 的 `.tint(AppTheme.accent)`，会跟品牌色错开一档。
                            isSelected ? AppTheme.accent : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 3 : 1
                        )
                )
                // 视觉 28pt，命中区补到 44pt（HIG 最小可点区域）
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        // §9 按下反馈：`.plain` 按下零反馈；强调层按 `Spacing.xs`(8) 内缩
        // （44 − 2×8 = 28）贴住这个 28pt 色块自身的圆，不在 44pt 命中框里铺成大圆盘。
        //
        // 强调层颜色必须**对比度感知**：色块有纯白 / 纯黑两档，`custom` 还是任意色。
        // 样式默认的 `Color.primary` 跟的是**明暗外观**（浅色下黑、深色下白），
        // 深色下压在纯白块、浅色下压在纯黑块时就与色块同色 —— 不透明度调多大都看不见。
        // 这里改成跟**色块自身亮度**走（见 `swatchHighlightColor`）：亮块配黑、暗块配白，
        // 强调层与色块因此**永远不同色**，且与当前是浅色还是深色外观无关。
        .buttonStyle(
            PressableCardButtonStyle(
                shape: AnyShape(Circle().inset(by: DesignTokens.Spacing.xs)),
                pressedHighlightColor: swatchHighlightColor(for: color)
            )
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 自定义背景色色卡（第二行）。色卡**本身就是 `ColorPicker` 的色块**：
    /// 点左卡直接开系统取色器改亮色、点右卡直接开系统取色器改暗色，各改各的。
    ///
    /// 为什么不能让色卡只当按钮、再弹一个取色器：`ColorPicker` 的取色器**只能由它自己的
    /// 色块被点开触发**，没有「用代码打开取色器」的 API，所以色卡必须直接就是那个色块。
    ///
    /// 选中态：`ColorPicker` 自身没有选中环，由外层叠一圈 `AppTheme.accent`
    /// （与第一行 `colorSwatch` 同一套观感：28pt 视觉 + 44pt 命中区）。
    /// 选中判据与改造前逐字一致：只看**当前外观**对应的那一个 ——
    /// 浅色外观 ↔ 亮色卡，深色外观 ↔ 暗色卡（`colorScheme` 见主类型里的说明）。
    private func customBackgroundPicker(isLight: Bool) -> some View {
        let label = isLight ? "自定义背景色（亮色）" : "自定义背景色（暗色）"
        let isSelected = configuration.backgroundStyle == .custom
            && colorScheme == (isLight ? .light : .dark)
        return ColorPicker(
            label,
            selection: isLight ? customBackgroundColorBinding : customBackgroundColorDarkBinding,
            supportsOpacity: false
        )
        .labelsHidden()
        // 外层补到 44pt（HIG 最小可点区域）；选中环按第一行色卡的 28pt 视觉尺寸对齐
        .frame(minWidth: 44, minHeight: 44)
        .overlay(
            Circle()
                .strokeBorder(
                    isSelected ? AppTheme.accent : Color.secondary.opacity(0.3),
                    lineWidth: isSelected ? 3 : 1
                )
                .frame(width: 28, height: 28)
                // 选中环只是视觉，绝不能吃掉取色器色块的点击
                .allowsHitTesting(false)
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 按下强调层的颜色：按色块自身的亮度配一个**反色**。
    ///
    /// 复用「文字颜色 = 跟随背景」那条既有规则（`ReaderAppearance.swift` 的
    /// `UIColor.isLightBackground`，阈值 0.6）：亮色块得到黑、暗色块得到白。
    /// 于是既不新增色值，也不另立一个亮度阈值（全仓只有一个亮度真相源）。
    /// 纯黑块不可能被判成亮色而配黑，纯白块也不可能被判成暗色而配白，
    /// 所以有效色块范围内强调层与色块**永远不会重合**。
    private func swatchHighlightColor(for background: UIColor) -> Color {
        Color(
            uiColor: ReadingTextColorMode.automatic.uiColor(
                on: background,
                custom: configuration.customBackgroundColor
            )
        )
    }

    /// 当前配置下某个背景预置的 UIKit 取值 —— 亮 / 暗两个自定义色都传进去
    /// （`ReadingBackgroundStyle.uiColor(custom:customDark:)` 是唯一入口，旧的一参转发已删）。
    private func backgroundUIColor(for style: ReadingBackgroundStyle) -> UIColor {
        style.uiColor(
            custom: configuration.customBackgroundColor,
            customDark: configuration.customBackgroundColorDark
        )
    }

    func binding<Value>(
        _ keyPath: WritableKeyPath<PaginationConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { configuration[keyPath: keyPath] },
            set: { newValue in
                var next = configuration
                next[keyPath: keyPath] = newValue
                onChange(next)
            }
        )
    }

    var fontNameBinding: Binding<String> {
        Binding(
            get: { configuration.fontName ?? "" },
            set: { newValue in
                var next = configuration
                next.fontName = newValue.isEmpty ? nil : newValue
                onChange(next)
            }
        )
    }

    /// 预缓存章数（`ReaderFeature.State.precacheCount`；`0 ... maxPrecacheCount` 的 clamp 在 reducer 里）。
    ///
    /// **语义与改造前逐字一致**：读 `precacheCount`、写 `onPrecacheCountChange` ——
    /// 只是把类型换成 `NumberInputRow` 要的 `CGFloat`（步长 1、下限 0 ⇒ `rounded()` 取整无损）。
    var precacheCountBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(precacheCount) },
            set: { onPrecacheCountChange(Int($0.rounded())) }
        )
    }

    /// 上边距（owner 2026-10-11）：**距屏幕顶的绝对距离**，`0` = 正文贴到屏幕最边缘
    /// （**不自己适配刘海 / 灵动岛**，内容可以被缺口盖住 —— owner 明确要这个）。
    ///
    /// 范围 `0 ... 200`、步长 2（默认 78 与两端都精确可达）。
    /// **只写 `inset.top`**：下边距有自己的滑杆（`bottomInsetBinding`），
    /// 旧实现那一个「同时写上下」的 `verticalInsetBinding` 已删 ——
    /// 它也正是旧文档里「竖向默认值必须对称」那条约束的来源，现已不成立。
    var topInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.inset.top },
            set: { newValue in
                var next = configuration
                next.inset.top = newValue
                onChange(next)
            }
        )
    }

    /// 下边距：同样只写自己那一侧，范围 `0 ... 120`、步长 2（默认 30 精确可达）。
    ///
    /// 上下限刻意与上边距不同（owner 指定 200 / 120）：下半屏还要给 Home Indicator
    /// 与底部翻页手势留出空间，能接受的最大留白比顶部小。
    var bottomInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.inset.bottom },
            set: { newValue in
                var next = configuration
                next.inset.bottom = newValue
                onChange(next)
            }
        )
    }

    /// 标签边距（owner 2026-10-11）：**三个角落标签共用**这一个值，范围 `0 ... 64`、步长 2。
    ///
    /// 默认 16 = `DesignTokens.Spacing.md`，与改造前 `ReaderCornerHUD` 里硬编码的那个值同值
    /// ⇒ 默认观感逐值不变。它**只改左右**（`ReaderCornerHUD` 的一条 `.padding(.horizontal)`），
    /// 垂直位置仍由 `topBarPadding(inset:)` / `bottomBarInset` 决定（与控制栏面板同源，见 `readerCornerHUD`）。
    var hudInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.hudHorizontalInset },
            set: { newValue in
                var next = configuration
                next.hudHorizontalInset = newValue
                onChange(next)
            }
        )
    }

    /// 上标签上边距（owner 2026-10-11 第二版口径）：**上栏面板上边缘距屏幕顶的绝对距离**，
    /// 范围 `0 ... 70`、默认 `0`、步长 2（默认与两端都精确可达）。
    ///
    /// `0` = 面板贴屏幕最上边（**不避让灵动岛 / 状态栏** —— owner 明确要这个默认值，
    /// ⛔ 别当成 bug 改回去）。**下限就是 `0`**：负值已按 owner 口径废弃，
    /// 老数据里的历史负值由 `mergedConfiguration` 收成 `0`。
    ///
    /// ## 为什么 `get` 里有一个 `?? 0`
    /// `configuration.topBarInset` 是 `CGFloat?`：`nil` = **老数据里没有这个 key**
    /// （「自动」机制已删，`nil` 不再是「自动」）⇒ 显示 `0`，与
    /// `ReadingSettings.mergedConfiguration(containerSize:)` 的兜底同值。
    /// ⚠️ 只在 `get` 里兜底：`set` 写的是用户输入的那个数（范围 `0 ... 70`，由 `NumberInputRow` 夹取）。
    var topBarInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.topBarInset ?? 0 },
            set: { newValue in
                var next = configuration
                next.topBarInset = newValue
                onChange(next)
            }
        )
    }

    /// 下标签下边距（owner 2026-10-11 第二版口径）：**下栏面板下边缘距屏幕底的距离**，
    /// 范围 `0 ... 70`、默认 `0`、步长 2。
    ///
    /// `0` = 面板贴屏幕最下边（**不避让 Home Indicator**）。**下限就是 `0`**：
    /// 负值已按 owner 口径废弃，老数据里的历史负值由 `mergedConfiguration` 收成 `0`。
    /// `configuration.bottomBarInset` 是非可选 `CGFloat` ⇒ 框里直接读写，不需要兜底。
    /// ⚠️ 它只动**下栏面板的下边缘**；跳章条与下栏之间的 8pt 间隙不跟它走。
    var bottomBarInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.bottomBarInset },
            set: { newValue in
                var next = configuration
                next.bottomBarInset = newValue
                onChange(next)
            }
        )
    }

    /// 左右边距（U1-8）。下限仍守 8pt；默认 24pt 由 `PageInset` 的默认值给。
    var horizontalInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.inset.leading },
            set: { newValue in
                var next = configuration
                next.inset.leading = newValue
                next.inset.trailing = newValue
                onChange(next)
            }
        )
    }

    /// 亮色自定义背景色。改色即把背景样式切到 `.custom`：第一行已过滤掉 `.custom`，
    /// 第二行的取色器是进入自定义模式的**唯一入口** —— 只改色不切样式，用户就再也进不去。
    var customBackgroundColorBinding: Binding<Color> {
        Binding(
            get: { configuration.customBackgroundColor.swiftUIColor },
            set: { newValue in
                var next = configuration
                next.customBackgroundColor = ReadingColor(newValue)
                next.backgroundStyle = .custom
                onChange(next)
            }
        )
    }

    /// 暗色自定义背景色（深色外观下生效）。与 `customBackgroundColorBinding` **对称**：
    /// 同样只写 `customBackgroundColorDark`，同样改色即切到 `.custom`（两个色卡互不影响）。
    var customBackgroundColorDarkBinding: Binding<Color> {
        Binding(
            get: { configuration.customBackgroundColorDark.swiftUIColor },
            set: { newValue in
                var next = configuration
                next.customBackgroundColorDark = ReadingColor(newValue)
                next.backgroundStyle = .custom
                onChange(next)
            }
        )
    }

    var customTextColorBinding: Binding<Color> {
        Binding(
            get: { configuration.customTextColor.swiftUIColor },
            set: { newValue in
                var next = configuration
                next.customTextColor = ReadingColor(newValue)
                onChange(next)
            }
        )
    }
}
