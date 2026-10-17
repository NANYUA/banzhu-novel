import NovelCore
import SwiftUI

/// 香色闺阁排版参数的设置行与绑定（`ReaderSettingsView` 的扩展）。
///
/// ## 为什么单独一个文件
/// `ReaderSettingsView.swift` 本体已经 560+ 行，紧贴 SwiftLint `file_length` 600 的红线
/// （warning 即 CI 红）。这一组是「章标题独立排版 + 正文粗细 + 首行缩进字数」——
/// 与既有「文字 / 外观 / 阅读」三段相对独立，正好按既有拆法（`X+子主题.swift`）搬出来。
///
/// ## 参数来源
/// 香色闺阁 `resources/plist_paibanKeyInfo.plist` 与 `plist_localConfig.plist` 的
/// `rmd_paibanListV2`（三套推荐排版：默认 / 紧凑 / 宽松）。取值范围照抄它的
/// `kv_valueMin … kv_valueMax`，默认值取它的「默认排版」一套。
extension ReaderSettingsView {
    /// 章标题的独立排版（香色闺阁 `title*` 一组参数：三套推荐排版都用 `1` 号增量 + `3` 字重）。
    ///
    /// 章标题在正文文本里就是**第一段**（`ReaderFeature.displayText` = 章名 + `"\n\n"` + 正文），
    /// 由 `ReaderPageTextView` / `TextKitMeasuring` 按「本章第 1 页」这条判据换成这组属性。
    var titleSection: some View {
        Section {
            NumberInputRow(
                title: "标题字号增量",
                value: titleFontSizeOffsetBinding,
                range: 0 ... 10,
                step: 1,
                focus: $focusedField
            )
            NumberInputRow(
                title: "标题粗细",
                value: titleFontWeightBinding,
                range: -10 ... 10,
                step: 1,
                focus: $focusedField
            )
            NumberInputRow(
                title: "标题字间距",
                value: titleCharacterSpacingBinding,
                range: -10 ... 20,
                step: 0.5,
                focus: $focusedField
            )
            NumberInputRow(
                title: "标题行距",
                value: titleLineSpacingBinding,
                range: -10 ... 100,
                step: 1,
                focus: $focusedField
            )
            NumberInputRow(
                title: "标题段间距",
                value: titleParagraphSpacingBinding,
                range: -10 ... 200,
                step: 2,
                focus: $focusedField
            )
        } header: {
            Text("章标题")
        } footer: {
            Text("只作用于每章第 1 页的章名那一行；字间距 / 行距 / 段间距默认跟随正文。")
        }
    }

    /// 首行缩进字数（`0 … 5`）：配置里是 `Int`，控件要 `CGFloat`（步长 1 ⇒ `rounded()` 取整无损）。
    var firstLineIndentCharsBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(configuration.firstLineIndentChars) },
            set: { newValue in
                var next = configuration
                next.firstLineIndentChars = Int(newValue.rounded())
                // 老字段同步：`isFirstLineIndentOn == false` 会让「字数」失效（见
                // `PaginationConfiguration.firstLineHeadIndent`），用户在这里改成非 0
                // 就必须把它打开，否则会出现「写着 3 字但没缩进」。
                next.isFirstLineIndentOn = next.firstLineIndentChars > 0
                onChange(next)
            }
        )
    }

    /// 正文字重（`-10 … 10`，`0` = 常规）。
    var fontWeightBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(configuration.fontWeight) },
            set: { newValue in
                var next = configuration
                next.fontWeight = Int(newValue.rounded())
                onChange(next)
            }
        )
    }

    /// 章标题字号增量（`0 … 10`）。
    var titleFontSizeOffsetBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.titleFontSizeOffset },
            set: { newValue in
                var next = configuration
                next.titleFontSizeOffset = newValue
                onChange(next)
            }
        )
    }

    /// 章标题字重（`-10 … 10`）。
    var titleFontWeightBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(configuration.titleFontWeight) },
            set: { newValue in
                var next = configuration
                next.titleFontWeight = Int(newValue.rounded())
                onChange(next)
            }
        )
    }

    /// 章标题字间距：`nil`（跟随正文）时显示正文当前值；一改就固定成显式值。
    var titleCharacterSpacingBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.resolvedTitleCharacterSpacing },
            set: { newValue in
                var next = configuration
                next.titleCharacterSpacing = newValue
                onChange(next)
            }
        )
    }

    /// 章标题行距：`nil` 时显示正文当前值。
    var titleLineSpacingBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.resolvedTitleLineSpacing },
            set: { newValue in
                var next = configuration
                next.titleLineSpacing = newValue
                onChange(next)
            }
        )
    }

    /// 章标题段间距：`nil` 时显示正文当前值。
    var titleParagraphSpacingBinding: Binding<CGFloat> {
        Binding(
            get: { configuration.resolvedTitleParagraphSpacing },
            set: { newValue in
                var next = configuration
                next.titleParagraphSpacing = newValue
                onChange(next)
            }
        )
    }
}
