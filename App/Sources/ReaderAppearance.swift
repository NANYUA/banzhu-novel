import Foundation
import NovelCore
import SwiftUI
import UIKit

extension ReadingColor {
    var uiColor: UIColor {
        UIColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    var swiftUIColor: Color {
        Color(uiColor: uiColor)
    }

    init(_ color: Color) {
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        } else {
            self = .defaultCustomBackground
        }
    }

    /// `#RRGGBB` 形式的十六进制串（阅读设置面板的 hex 输入框回显用）。
    ///
    /// 透明度**不参与**：自定义背景色恒为不透明（`ColorPicker` 也关掉了 `supportsOpacity`）。
    /// 通道值一律先 `rounded()` 再转 `Int`（**不用 `UInt8`**：越界值会直接触发运行时陷阱，
    /// 而这个值可能来自手工改过的持久化 JSON）。
    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    /// 解析 `#RRGGBB` / `RRGGBB`（6 位十六进制，大小写皆可）；不合法返回 `nil`。
    ///
    /// 只认 6 位：3 位缩写（`#FFF`）与 8 位带透明度（`#RRGGBBAA`）都判非法 ——
    /// 自定义背景色恒不透明，接受透明度会制造"输入了却不生效"的歧义。
    /// 非法的输入由调用方（`ReaderSettingsView` 的 hex 输入框）**丢弃**，配置保留上一个有效值。
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// 阅读页「跟随」预置的浅 / 深两个取值。
///
/// **只作用于阅读页**：App 全局底色仍是 `AppTheme.Surface.page`（`systemGroupedBackground`，
/// 深色纯黑），owner 明确只改阅读页。
private enum ReaderFollowBackground {
    /// 浅色：`systemGroupedBackground` 的浅色取值 #F2F2F7（与改动前逐值一致）。
    static let light = UIColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1)
    /// 深色：**#161616**（owner 指定）。
    static let dark = UIColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255, alpha: 1)
}

extension ReadingBackgroundStyle {
    var displayName: String {
        switch self {
        case .white:
            "跟随"
        case .sepia:
            "米黄"
        case .eyeCare:
            "护眼绿"
        case .black:
            "纯黑"
        case .custom:
            "自定义"
        }
    }

    /// 预置背景色的 UIKit 取值。
    ///
    /// ⚠️ `case .white` 的**原始值刻意没改名**（仍叫 `white`）：它是 `Codable` 的持久化
    /// 原始值，改名会让已落盘的阅读设置解码失败、退回默认值。改的只是它**渲染成什么颜色**。
    ///
    /// `custom` 是亮色外观下的自定义背景色，`customDark` 是深色外观下的（阅读界面改版：
    /// 自定义背景色**亮暗分开**）。
    func uiColor(custom: ReadingColor, customDark: ReadingColor) -> UIColor {
        switch self {
        case .white:
            // 「跟随」= App 总背景（U9-4：阅读外观背景色跟随软件总背景）。
            // 浅色仍是 `systemGroupedBackground` 的浅色值 #F2F2F7（与 `AppTheme.Surface.page`
            // 同源）；深色**刻意改成 #161616**（owner 指定，只动阅读页 ——
            // `AppTheme.Surface.page` 仍是纯黑，App 全局不受影响）。
            //
            // 取色方式仍是**动态色**：不能写 `UIColor(AppTheme.Surface.page)` ——
            // `UIColor(Color)` 桥接会把动态色解析成调用当时的静态值，切明暗外观就不会跟着变了。
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? ReaderFollowBackground.dark
                    : ReaderFollowBackground.light
            }
        case .sepia:
            UIColor(red: 0.96, green: 0.93, blue: 0.84, alpha: 1)
        case .eyeCare:
            UIColor(red: 0.80, green: 0.91, blue: 0.80, alpha: 1)
        case .black:
            .black
        case .custom:
            // 自定义背景色亮暗分开：浅色外观用 `custom`、深色外观用 `customDark`。
            // 两个取值本身都是静态色，包进 dynamicProvider 里按 traits 二选一即可
            // （用户没改过时二者同为 `defaultCustomBackground`，行为不突变）。
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? customDark.uiColor : custom.uiColor
            }
        }
    }
}

extension ReadingTextColorMode {
    var displayName: String {
        switch self {
        case .automatic:
            "跟随背景"
        case .custom:
            "自定义"
        }
    }

    func uiColor(on background: UIColor, custom: ReadingColor) -> UIColor {
        switch self {
        case .automatic:
            // 「跟随背景」= 按**背景自身的明暗**选黑 / 白。
            //
            // 刻意做成**动态色**（与 `AppTheme.accent` 同一手法）：背景可能是动态语义色
            // （「跟随」预置 = `systemGroupedBackground`，U9-4），而 `UIColor.getRed` 解析动态色
            // 用的是 `UITraitCollection.current` —— 在 `UIViewRepresentable.updateUIView` 里
            // 那个值不可靠（不是 UIKit 的绘制回调）。若在这里就地解析一次，深色外观下会拿
            // 浅色背景算出「黑字」，压在真·黑底上就是**隐形文字**。
            // 包成 dynamicProvider 后，文字与背景**在同一套 traits 下**一起解析，永远配套。
            //
            // 对既有静态背景（白 / 米黄 / 护眼绿 / 纯黑 / 自定义）行为**逐值不变**：
            // `resolvedColor(with:)` 对静态色返回它自己。
            UIColor { traits in
                background.resolvedColor(with: traits).isLightBackground ? .black : .white
            }
        case .custom:
            custom.uiColor
        }
    }
}

extension ReadingAppearanceMode {
    var displayName: String {
        switch self {
        case .system:
            "跟随系统"
        case .light:
            "浅色"
        case .dark:
            "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

private extension UIColor {
    var isLightBackground: Bool {
        relativeLuminance > 0.6
    }

    var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return 0.299 * red + 0.587 * green + 0.114 * blue
        }
        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) {
            return white
        }
        return 1
    }
}
