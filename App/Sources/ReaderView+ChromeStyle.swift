import NovelCore
import SwiftUI
import UIKit

// 阅读页控制栏的**样式派生**：从正文底色算出玻璃染色、边缘线、阴影与前景色。
//
// 与 `ReaderView+Chrome.swift`（栏体 / 布局 / 转场）拆成两个文件，理由与
// `ReaderView+PageTurn.swift` 当初拆出去时相同：`file_length` 红线 600，
// 把「派生规则 + 视图」塞进一个文件会直接顶到红线。本文件只管「颜色从哪来」，
// 不出现任何布局。
//
// ## 不照抄参考实现，全部落在项目既有资产上
// - 明暗判定用项目**唯一**的亮度真相源 `UIColor.isLightBackground` / `relativeLuminance`
//   （`ReaderAppearance.swift`，阈值 **0.6**）。参考实现是自算 BT.601 亮度、阈值 **0.40**，
//   已统一到 0.6 —— 具体影响见 `ReaderChromeDerivation.tint(for:)`；
// - 前景色（图标 / 标题）走 `ReadingTextColorMode.automatic.uiColor(on:custom:)` ——
//   全仓只有这一条「背景上的文字 / 图标用什么颜色」的规则；
// - 参考实现的 `RGBColor` + 自算 `luminance` 换成项目既有的 `ReadingColor`（NovelCore），
//   只补「插值 / 缩放 / 从已解析 `UIColor` 取分量」三个私有方法，不新造颜色类型。

// MARK: - 派生配方

/// 玻璃的派生配方：**每一项都从「正文底色」算出来**。
///
/// 所以这里不是颜色令牌，而是「怎么从底色算出这一档」的取值 ——
/// 颜色本身在运行时派生（见 `ReaderChromeStyle.make(page:)`）。
private enum ReaderChromeDerivation {
    /// 系统毛玻璃：保留 iOS 原生材质质感，不改成不透明色块。
    /// 不用 iOS 26 的液态玻璃材质（与 `PressableCardButtonStyle` 的基线一致）。
    static let material: Material = .regularMaterial

    /// 0.18 —— 染色先向「同亮度的灰」靠拢 18%：去掉一点底色彩度，
    /// 玻璃才不会是一块高饱和色块（这是「同色系、略有明度差」里的「略有」）。
    static let desaturation = 0.18

    /// 0.90 —— 浅色底：整体压暗 10%。只压暗、不改色相，才能保持「同色系」。
    static let lightDimFactor = 0.90

    /// 深色底的目标玻璃色 #3C3C3F（0.235 / 0.235 / 0.247）：比纯黑正文亮一档的深灰；
    /// 蓝通道略高（0.247）是为了让深灰玻璃不发死。
    static let darkTintTarget = ReadingColor(red: 0.235, green: 0.235, blue: 0.247)

    /// 0.90 —— 深色底向上面那个深灰靠拢 90%：几乎完全成为深灰玻璃，只留 10% 原底色。
    static let darkTintMix = 0.90

    /// 染色强度按深浅分三档（烘焙进染色色的 alpha，理由见 `ReaderChromeStyle` 的类型注释）：
    /// - 深色底 0.60：深色玻璃要压住材质自身的亮度，否则会发灰发雾；
    /// - 近纯白 0.45：纯白底上染色重了显脏，减淡一档；
    /// - 其余浅色底 0.52：中间档 —— 按钮清晰，又透得出玻璃感。
    static let darkTintOpacity: CGFloat = 0.60
    static let nearWhiteTintOpacity: CGFloat = 0.45
    static let lightTintOpacity: CGFloat = 0.52

    /// 0.92 —— 「近纯白」的分档阈值（与亮度真相源同一套 BT.601 公式，只是另一档分界）。
    /// 为什么另设一档：纯白底上 0.10 的边缘线与阴影几乎看不见，必须加强（见下）。
    static let nearWhiteLuminance: CGFloat = 0.92

    /// 边缘线不透明度：深色底用浅色线（0.12）、浅色底用深色线（0.10）、近纯白加强到 0.14。
    static let darkEdgeOpacity: CGFloat = 0.12
    static let lightEdgeOpacity: CGFloat = 0.10
    static let nearWhiteEdgeOpacity: CGFloat = 0.14

    /// 阴影不透明度：深色底 0.30（黑底上的影子要更实才看得出层次）、浅色底 0.10、近纯白 0.13。
    static let darkShadowOpacity: CGFloat = 0.30
    static let lightShadowOpacity: CGFloat = 0.10
    static let nearWhiteShadowOpacity: CGFloat = 0.13

    /// 10 —— 投影半径。参考实现给的是「深色 12 / 浅色 10」，两档只差 2pt、观感上不可辨；
    /// 而「该取哪一档」依赖的是**正文底色**的明暗（不是外观明暗），要在视图层拿到这个布尔值，
    /// 就得再解析一次动态色 —— 那正是本项目刻意避免的第二套解析路径（见 `ReaderChromeStyle`）。
    /// 故统一取 10pt。
    static let shadowRadius: CGFloat = 10

    /// 染色色 = 去饱和后的底色，按**正文底色**的深浅压暗 / 提亮，并把染色强度烘焙进 alpha。
    ///
    /// ⚠️ 深浅判据统一到项目既有的 `UIColor.isLightBackground`（阈值 **0.6**）。
    /// 参考实现原来自算 BT.601 亮度、阈值 **0.40**，两者只在「亮度落在 (0.40, 0.60] 区间」
    /// 时结论不同：
    /// - 五个预置背景（跟随 #F2F2F7 / #161616、米黄 0.93、护眼绿 0.86、纯黑 0）**全部不受影响**
    ///   （它们要么 > 0.92、要么 < 0.1，离这段区间很远）；
    /// - 只有**自定义背景色**且亮度恰好落在这段区间时，明暗判定从「浅」翻成「深」
    ///   ⇒ 玻璃从「压暗的灰调」变成「深灰玻璃」。这正是要统一阈值的原因：同一块底色，
    ///   正文文字选黑 / 白与玻璃选深 / 浅必须是同一个判据。
    static func tint(for page: UIColor) -> UIColor {
        let luminance = page.relativeLuminance
        // `ReadingColor` 的分量是 `Double`（纯逻辑层不依赖 CoreGraphics），这里显式转换。
        let grayLevel = Double(luminance)
        let gray = ReadingColor(red: grayLevel, green: grayLevel, blue: grayLevel)
        let desaturated = ReadingColor(resolved: page).mixed(with: gray, desaturation)
        if page.isLightBackground {
            let opacity = luminance > nearWhiteLuminance ? nearWhiteTintOpacity : lightTintOpacity
            return desaturated.scaled(lightDimFactor).uiColor.withAlphaComponent(opacity)
        }
        let glass = desaturated.mixed(with: darkTintTarget, darkTintMix)
        return glass.uiColor.withAlphaComponent(darkTintOpacity)
    }

    /// 边缘线颜色：**朝正文那一侧**的那根 0.5pt 细线。
    ///
    /// 为什么用 `UIColor.black` / `.white` 而不是 `AppTheme` 的语义色：
    /// 边缘线要跟**正文底色**的明暗走，而 `UIColor.label` 这类语义色跟的是**外观**明暗 ——
    /// 「深色外观 + 护眼绿底」时两者正好相反（底色是亮的，语义色却是白的），线就看不见了。
    static func edge(for page: UIColor) -> UIColor {
        guard page.isLightBackground else { return UIColor.white.withAlphaComponent(darkEdgeOpacity) }
        let opacity = page.relativeLuminance > nearWhiteLuminance ? nearWhiteEdgeOpacity : lightEdgeOpacity
        return UIColor.black.withAlphaComponent(opacity)
    }

    /// 阴影色：恒为黑 —— 影子是「遮光」，深色底也要靠黑影压出层次（白影会变成发光）。
    static func shadow(for page: UIColor) -> UIColor {
        guard page.isLightBackground else { return UIColor.black.withAlphaComponent(darkShadowOpacity) }
        let opacity = page.relativeLuminance > nearWhiteLuminance ? nearWhiteShadowOpacity : lightShadowOpacity
        return UIColor.black.withAlphaComponent(opacity)
    }
}

// MARK: - 样式

/// 控制栏的一套视觉令牌：玻璃（系统材质 + 主题染色）、边缘线、投影、前景色。
///
/// ## 为什么是一组「派生」令牌
/// 上下栏不是一块固定的白玻璃：它必须**与正文同色系、只有明度差**，换主题
/// （跟随 / 米黄 / 护眼绿 / 纯黑 / 自定义）时跟着正文走。所以所有颜色都从**正文底色**算出来，
/// 不写死色值。
///
/// ## 为什么颜色都是动态色
/// 正文底色本身可能是动态色（「跟随」预置 = `systemGroupedBackground` 的浅 / 深两版），
/// 而 `UIColor.getRed` 解析动态色用的是 `UITraitCollection.current` —— 在阅读页
/// `.preferredColorScheme` 强制外观时并不可靠。所以这里与 `ReadingTextColorMode.automatic`
/// 同一手法：把「按 traits 解析 → 派生」整段包进 `UIColor { traits in ... }`，
/// 让底色与派生色**在同一套 traits 下**一起解析。
///
/// 也正因为如此，**染色强度烘焙进染色色的 alpha**，而不是另存一个「只对某一种外观成立」的
/// `Double` —— 那个标量没法随 traits 变化，存下来就一定会有一半外观算错。
struct ReaderChromeStyle {
    var material: Material
    var tint: Color
    var edgeColor: Color
    var shadowColor: Color
    var shadowRadius: CGFloat
    var foreground: Color

    /// 从**正文底色**派生整套控制栏样式。
    ///
    /// - 前景色刻意用 `.automatic`（而不是用户在阅读设置里选的 `textColorMode`）：
    ///   控制栏的图标 / 标题压在**玻璃**上，必须跟随背景明暗；用户自定义正文色是给正文用的，
    ///   压在这层玻璃上可能直接不可读。
    static func make(page: UIColor) -> ReaderChromeStyle {
        ReaderChromeStyle(
            material: ReaderChromeDerivation.material,
            tint: Color(uiColor: UIColor { traits in
                ReaderChromeDerivation.tint(for: page.resolvedColor(with: traits))
            }),
            edgeColor: Color(uiColor: UIColor { traits in
                ReaderChromeDerivation.edge(for: page.resolvedColor(with: traits))
            }),
            shadowColor: Color(uiColor: UIColor { traits in
                ReaderChromeDerivation.shadow(for: page.resolvedColor(with: traits))
            }),
            shadowRadius: ReaderChromeDerivation.shadowRadius,
            foreground: Color(uiColor: ReadingTextColorMode.automatic.uiColor(
                on: page,
                custom: .defaultCustomText
            ))
        )
    }
}

// MARK: - 颜色工具

private extension ReadingColor {
    /// 从**已解析**的静态 `UIColor` 取分量（动态色请先 `resolvedColor(with:)`，
    /// 否则 `getRed` 会按 `UITraitCollection.current` 解析）。
    ///
    /// 与 `ReaderAppearance.init(_ color: Color)` 同一手法，只是那边从 SwiftUI `Color` 取。
    init(resolved color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        } else {
            var white: CGFloat = 0
            if color.getWhite(&white, alpha: &alpha) {
                self.init(red: Double(white), green: Double(white), blue: Double(white), alpha: Double(alpha))
            } else {
                // 图案色 / 取不到分量的颜色（正文底色不会走到这里）：退回中灰，保证派生仍可计算。
                self.init(red: 0.5, green: 0.5, blue: 0.5)
            }
        }
    }

    /// 线性插值到另一颜色（去饱和、向深灰靠拢都用它）。
    func mixed(with other: ReadingColor, _ amount: Double) -> ReadingColor {
        ReadingColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            alpha: alpha
        )
    }

    /// 整体明度缩放（浅色底压暗一档）。
    func scaled(_ factor: Double) -> ReadingColor {
        ReadingColor(
            red: min(red * factor, 1),
            green: min(green * factor, 1),
            blue: min(blue * factor, 1),
            alpha: alpha
        )
    }
}
