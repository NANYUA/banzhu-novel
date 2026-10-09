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
                    "自定义背景色",
                    selection: customBackgroundColorBinding,
                    supportsOpacity: false
                )
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
                Text("页边距")
                Slider(value: pageInsetBinding, in: 8 ... 48, step: 4)
                Text("\(Int(configuration.inset.top))")
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
            Picker("翻页方式", selection: binding(\.pageTurnMode)) {
                ForEach(PageTurnMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("翻页动画", selection: binding(\.pageTurnAnimation)) {
                ForEach(PageTurnAnimation.allCases, id: \.self) { animation in
                    Text(animation.displayName).tag(animation)
                }
            }
            .pickerStyle(.segmented)

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
                .fill(Color(uiColor: style.uiColor(custom: configuration.customBackgroundColor)))
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 3 : 1
                        )
                )
                // 视觉 28pt，命中区补到 44pt（HIG 最小可点区域）
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private extension ReaderSettingsView {
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

    var pageInsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.inset.top },
            set: { newValue in
                var next = configuration
                next.inset = PageInset(
                    top: newValue,
                    leading: newValue,
                    bottom: newValue,
                    trailing: newValue
                )
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
