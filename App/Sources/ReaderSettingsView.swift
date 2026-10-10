import Foundation
import NovelCore
import SwiftUI
import UIKit

/// 一项候选字体：Picker 显示 `displayName`，写回 `configuration.fontName` 的是 `familyName`。
private struct ReaderFontOption {
    let displayName: String
    let familyName: String
}

/// 自定义背景色的两个 hex 输入框（亮色 / 暗色），用于跟踪"当前聚焦的是哪一个"。
private enum HexColorField: Hashable {
    case light
    case dark
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

    /// hex 输入框的**草稿文本**：`nil` = 未编辑、跟随配置；非 nil = 用户敲进去的原始串。
    /// 必须留草稿，否则每敲一键都回写 —— hex 打到一半（如 `#F2F`）必然非法，
    /// 输入框会跟用户抢输入，一个色值也打不完。
    @State private var lightHexDraft: String?
    @State private var darkHexDraft: String?

    /// 当前聚焦的 hex 输入框：**失焦时丢弃非法草稿**，让文字退回当前有效值
    /// （apple-design-2 §11 就地校验：不让用户看着一个没生效的串以为生效了）。
    @FocusState private var focusedHexField: HexColorField?

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
                Slider(value: fontSizeBinding, in: 12 ... 30, step: 1)
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
                    ForEach(ReadingBackgroundStyle.allCases, id: \.self) { style in
                        backgroundSwatch(style)
                    }
                }
            }

            if configuration.backgroundStyle == .custom {
                ColorPicker(
                    "亮色背景色",
                    selection: customBackgroundColorBinding,
                    supportsOpacity: false
                )

                customBackgroundHexFields
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

            HStack {
                Text("上下边距")
                Slider(value: verticalInsetBinding, in: -60 ... 48, step: 4)
                Text("\(Int(configuration.inset.top))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }

            HStack {
                Text("左右边距")
                Slider(value: horizontalInsetBinding, in: 8 ... 48, step: 4)
                Text("\(Int(configuration.inset.leading))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 32, alignment: .trailing)
            }

            Toggle("亮度跟随系统", isOn: binding(\.followsSystemBrightness))
        }
    }

    // MARK: - 阅读

    private var readingSection: some View {
        Section("阅读") {
            Toggle("首行缩进", isOn: firstLineIndentBinding)

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

    private func backgroundSwatch(_ style: ReadingBackgroundStyle) -> some View {
        let isSelected = configuration.backgroundStyle == style
        return Button {
            var next = configuration
            next.backgroundStyle = style
            onChange(next)
        } label: {
            Circle()
                .fill(Color(uiColor: backgroundUIColor(for: style)))
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
                pressedHighlightColor: swatchHighlightColor(for: style)
            )
        )
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension ReaderSettingsView {
    /// 按下强调层的颜色：按色块自身的亮度配一个**反色**。
    ///
    /// 复用「文字颜色 = 跟随背景」那条既有规则（`ReaderAppearance.swift` 的
    /// `UIColor.isLightBackground`，阈值 0.6）：亮色块得到黑、暗色块得到白。
    /// 于是既不新增色值，也不另立一个亮度阈值（全仓只有一个亮度真相源）。
    /// 纯黑块不可能被判成亮色而配黑，纯白块也不可能被判成暗色而配白，
    /// 所以有效色块范围内强调层与色块**永远不会重合**。
    ///
    /// 放 extension 里：`type_body_length` 不统计 extension，而主类型 body 本就贴着门槛。
    private func swatchHighlightColor(for style: ReadingBackgroundStyle) -> Color {
        let background = backgroundUIColor(for: style)
        return Color(
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

    var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.fontSize },
            set: { newValue in
                var next = configuration
                next.fontSize = newValue
                if next.firstLineHeadIndent > 0 {
                    next.firstLineHeadIndent = newValue * 2
                }
                onChange(next)
            }
        )
    }

    var firstLineIndentBinding: Binding<Bool> {
        Binding(
            get: { configuration.firstLineHeadIndent > 0 },
            set: { isOn in
                var next = configuration
                next.firstLineHeadIndent = isOn ? configuration.fontSize * 2 : 0
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

    /// 上下边距（U1-8）：与左右分开可调 —— 原先一个「页边距」滑杆同时改四边。
    ///
    /// 滑杆范围 `-60 ... 48`（owner 决定放开负值）：**负值让正文侵入上下安全区**，
    /// 最多多出 60pt 正文高度；上限仍是 48pt。上下不需要 HIG 那套水平页边距的下限
    /// （左右边距的下限仍守 8pt，见 `horizontalInsetBinding`）。
    var verticalInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.inset.top },
            set: { newValue in
                var next = configuration
                next.inset.top = newValue
                next.inset.bottom = newValue
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

    var customBackgroundColorBinding: Binding<Color> {
        Binding(
            get: { configuration.customBackgroundColor.swiftUIColor },
            set: { newValue in
                var next = configuration
                next.customBackgroundColor = ReadingColor(newValue)
                onChange(next)
            }
        )
    }

    /// 亮色自定义背景色的 hex 输入框绑定（与 `customBackgroundColorBinding` 写**同一份配置**）。
    var customBackgroundColorHexBinding: Binding<String> {
        hexTextBinding(
            draft: $lightHexDraft,
            current: configuration.customBackgroundColor
        ) { color in
            var next = configuration
            next.customBackgroundColor = color
            onChange(next)
        }
    }

    /// 暗色自定义背景色的 hex 输入框绑定：与上面那个**对称**，只是写 `customBackgroundColorDark`。
    var customBackgroundColorDarkHexBinding: Binding<String> {
        hexTextBinding(
            draft: $darkHexDraft,
            current: configuration.customBackgroundColorDark
        ) { color in
            var next = configuration
            next.customBackgroundColorDark = color
            onChange(next)
        }
    }

    /// 亮 / 暗两个 hex 输入框（与上面的 `ColorPicker` 并存：取色器负责「挑」，输入框负责「精确填」）。
    var customBackgroundHexFields: some View {
        Group {
            hexColorField(
                title: "亮色代码",
                accessibilityLabel: "亮色自定义背景色，输入颜色代码",
                field: .light,
                text: customBackgroundColorHexBinding
            )
            hexColorField(
                title: "暗色代码",
                accessibilityLabel: "暗色自定义背景色，输入颜色代码",
                field: .dark,
                text: customBackgroundColorDarkHexBinding
            )
        }
        // 焦点一旦离开某个输入框，就丢掉它的草稿 → 文字被 `get` 拉回当前有效值。
        .onChange(of: focusedHexField) { previous, _ in
            revertHexDraft(previous)
        }
        // 取色器改了颜色 ⇒ 同侧的草稿作废，输入框立刻显示新色值（否则会停在旧串上）。
        .onChange(of: configuration.customBackgroundColor) { _, _ in
            lightHexDraft = nil
        }
        .onChange(of: configuration.customBackgroundColorDark) { _, _ in
            darkHexDraft = nil
        }
    }

    /// 一行 hex 输入框：左边标签，右边等宽输入区。
    ///
    /// 触控目标：`Form` 的行本身已是 44pt 高（HIG §9 最小可点区域），输入框撑满行高。
    private func hexColorField(
        title: String,
        accessibilityLabel: String,
        field: HexColorField,
        text: Binding<String>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("#F2F2F7", text: text)
                .multilineTextAlignment(.trailing)
                .monospaced()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedHexField, equals: field)
                // 回车不一定失焦：这里也要丢草稿，否则无效串会一直留在框里。
                .onSubmit { revertHexDraft(field) }
                .accessibilityLabel(accessibilityLabel)
        }
    }

    /// hex 文本 ⇄ `ReadingColor` 的桥。
    ///
    /// `get`：有草稿就回吐草稿（**不与正在输入的用户抢光标**），否则回吐当前有效值的 `#RRGGBB`。
    /// `set`：**能解析才写回配置**；解析失败只更新草稿 —— 配置保留上一个有效值，
    /// 既不写坏配置也不会崩（`ReadingColor(hex:)` 解析失败返回 `nil`，不是陷阱）。
    private func hexTextBinding(
        draft: Binding<String?>,
        current: ReadingColor,
        apply: @escaping (ReadingColor) -> Void
    ) -> Binding<String> {
        Binding(
            get: { draft.wrappedValue ?? current.hexString },
            set: { text in
                guard let color = ReadingColor(hex: text) else {
                    draft.wrappedValue = text
                    return
                }
                draft.wrappedValue = nil
                apply(color)
            }
        )
    }

    /// 丢掉指定输入框的草稿；`nil`（焦点离开全部输入框）时无事可做。
    private func revertHexDraft(_ field: HexColorField?) {
        switch field {
        case .light:
            lightHexDraft = nil
        case .dark:
            darkHexDraft = nil
        case nil:
            break
        }
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
