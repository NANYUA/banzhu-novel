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

            HStack {
                Text("字号")
                Slider(value: binding(\.fontSize), in: 12 ... 30, step: 1)
                Text("\(Int(configuration.fontSize))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }

            HStack {
                Text("行距")
                Slider(value: binding(\.lineSpacing), in: 0 ... 20, step: 1)
                Text("\(Int(configuration.lineSpacing))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }

            HStack {
                Text("段间距")
                Slider(value: binding(\.paragraphSpacing), in: 0 ... 30, step: 2)
                Text("\(Int(configuration.paragraphSpacing))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }

            HStack {
                Text("字间距")
                Slider(value: binding(\.characterSpacing), in: -1 ... 5, step: 0.5)
                Text(String(format: "%.1f", configuration.characterSpacing))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }

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

            // 上下边距**拆成两个滑杆**（owner 2026-10-11）：语义是「距**屏幕边缘**的绝对距离」，
            // `0` = 正文贴到屏幕最边缘（**不自己适配刘海**），上 `0…200`、下 `0…120`。
            // 两个滑杆**各改各的**（旧实现那一个滑杆同时写 `top` 与 `bottom`，已删）。
            // 步长 2：默认 78 / 30 与两端都能精确取到（`0/30/78/120/200` 全是偶数）。
            insetSlider("上边距", value: topInsetBinding, range: 0 ... 200, step: 2)
            insetSlider("下边距", value: bottomInsetBinding, range: 0 ... 120, step: 2)
            // 左右边距（U1-8）：下限仍守 8pt、默认 24pt 由 `PageInset` 的默认值给 —— 本次未改。
            insetSlider("左右边距", value: horizontalInsetBinding, range: 8 ... 48, step: 4)
            // 标签边距（owner 2026-10-11）：三个角落标签（左上书名 / 章节名、左下电量、右下页码）
            // **共用**这一个值，只调它们距屏幕左 / 右边缘的距离 —— 垂直位置不受它影响。
            insetSlider("标签边距", value: hudInsetBinding, range: 0 ... 64, step: 2)

            Toggle("亮度跟随系统", isOn: binding(\.followsSystemBrightness))
        }
    }

    // MARK: - 阅读

    private var readingSection: some View {
        Section("阅读") {
            // 首行缩进**默认打开**（owner 口径）：开关状态单独存（`isFirstLineIndentOn`），
            // 缩进宽度由 `fontSize × 2` 派生（`PaginationConfiguration.firstLineHeadIndent`）
            // ⇒ 改字号不再需要在这里手动同步缩进值。
            Toggle("首行缩进", isOn: binding(\.isFirstLineIndentOn))

            Stepper(
                value: precacheCountBinding,
                in: 0 ... ReaderFeature.maxPrecacheCount
            ) {
                Text("预缓存 \(precacheCount) 章")
            }

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

    /// 一条「标题 + 滑杆 + 右侧数值」的边距行。
    ///
    /// 四行（上 / 下 / 左右 / 标签边距）共用同一套版式与数值显示，逐值沿用既有写法
    /// （`Int(...)` 截断 + `.monospacedDigit()` + 32pt 右对齐）。
    /// 抽成函数是因为 `appearanceSection` 本就接近 SwiftLint `function_body_length`
    /// 的 50 行门槛（warning 即 CI 红），四段内联 HStack 会直接顶穿。
    ///
    /// 数值直接读 `value.wrappedValue`，不再单独传一份 `current`：
    /// 少一个参数，也就少一处「显示值与实际值不同源」的机会。
    ///
    /// ⚠️ 范围 / 步长是**业务常量**，仍就地写在调用处（与文件里其它滑杆一致）：
    /// 上下边距的范围见 `PageInset` 的文档。
    private func insetSlider(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text("\(Int(value.wrappedValue))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .trailing)
        }
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

    var precacheCountBinding: Binding<Int> {
        Binding(
            get: { precacheCount },
            set: { onPrecacheCountChange($0) }
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
    /// 垂直位置仍由 `topBarPadding` / `Spacing.xs` 决定。
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
