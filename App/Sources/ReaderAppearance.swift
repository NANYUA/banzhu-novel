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
    func uiColor(custom: ReadingColor) -> UIColor {
        switch self {
        case .white:
            // 「跟随」= App 总背景（U9-4：阅读外观背景色跟随软件总背景）。
            // 语义色与 `AppTheme.Surface.page`（`Color(.systemGroupedBackground)`）**同源**：
            // 浅色 #F2F2F7、深色纯黑。这里直接用 UIKit 语义色而不是 `UIColor(AppTheme.Surface.page)`：
            // `UIColor(Color)` 桥接会把动态色解析成调用当时的静态值，切明暗外观就不会跟着变了。
            .systemGroupedBackground
        case .sepia:
            UIColor(red: 0.96, green: 0.93, blue: 0.84, alpha: 1)
        case .eyeCare:
            UIColor(red: 0.80, green: 0.91, blue: 0.80, alpha: 1)
        case .black:
            .black
        case .custom:
            custom.uiColor
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

extension PageTurnMode {
    var displayName: String {
        switch self {
        case .slide:
            "左右滑动"
        case .tap:
            "点击翻页"
        case .scroll:
            "上下滚动"
        }
    }
}

extension PageTurnAnimation {
    var displayName: String {
        switch self {
        case .none:
            "无"
        case .cover:
            "覆盖"
        case .curl:
            "仿真"
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
