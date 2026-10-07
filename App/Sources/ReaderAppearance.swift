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
            "白色"
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

    func uiColor(custom: ReadingColor) -> UIColor {
        switch self {
        case .white:
            UIColor(white: 1, alpha: 1)
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
            background.isLightBackground ? .black : .white
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
