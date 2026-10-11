import NovelCore
import SwiftUI
import UIKit

// 阅读页控制栏的**样式派生**：面板底色（系统语义色）、边缘线、阴影与前景色。
//
// 与 `ReaderView+Chrome.swift`（栏体 / 布局 / 转场）拆成两个文件，理由与
// `ReaderView+PageTurn.swift` 当初拆出去时相同：`file_length` 红线 600，
// 把「派生规则 + 视图」塞进一个文件会直接顶到红线。本文件只管「颜色从哪来」，
// 不出现任何布局。
//
// ## 颜色不再跟随正文（owner 2026-10-11：上下栏改成系统颜色）
// 旧版从**正文底色**派生：去饱和 → 浅色压暗 ×0.90 / 深色向 #3C3C3F 提亮 → 烘三档 alpha。
// 后果是「上下栏与右上角系统「更多」菜单不同色」—— 菜单是系统材质色，面板却是被正文染过的色
// （米黄正文 ⇒ 米黄玻璃）。现在面板底色恒为**系统语义色** `secondarySystemBackground`
// （浅色 #F2F2F7 一档、深色 #1C1C1E 一档），与系统菜单同族、随明暗外观自动适配
// ⇒ 与正文是什么颜色**无关**（米黄 / 护眼绿 / 纯黑都不再影响它）。
//
// ## 明暗判定仍只有一条
// 前景色（图标 / 标题 / 文字）与边缘线的深浅，全部按**同一个**判据算：项目唯一的亮度真相源
// `UIColor.isLightBackground`（`ReaderAppearance.swift`，阈值 **0.6**）—— 前景色经
// `ReadingTextColorMode.automatic.uiColor(on:custom:)` 走它，边缘线直接调它。
// **没有**第二套亮度算法、**没有**第二个阈值；只是喂进去的「背景」从正文底色换成了
// **面板自己的底色**（图标实际坐着的那一层）。

// MARK: - 派生配方

/// 玻璃的派生配方：**全部由系统语义色与明暗外观决定**，与正文底色无关。
///
/// 旧版那套「按正文底色分档」的取值（去饱和 / 浅色压暗 / 深色向深灰提亮 / 三档染色 alpha /
/// 近纯白分档）已整体删除：面板底色在同一外观下是**常量**，这些步骤不再有任何输入可变。
private enum ReaderChromeDerivation {
    /// 系统毛玻璃：保留 iOS 原生材质质感，不改成纯色块。
    /// 不用 iOS 26 的液态玻璃材质（与 `PressableCardButtonStyle` 的基线一致）。
    static let material: Material = .regularMaterial

    /// 面板底色的**唯一来源**：系统语义色 `secondarySystemBackground`
    /// （浅色 #F2F2F7 一档的浅灰、深色 #1C1C1E 一档的系统深灰）。
    ///
    /// 为什么不用 `systemGroupedBackground`（`AppTheme.Surface.page` 那个）：它深色档是**纯黑**，
    /// 面板会与深色正文（跟随深色 ≈ #161616、纯黑预置 = #000000）糊成一片，浮不起来。
    /// 为什么不用 `secondarySystemGroupedBackground`：它浅色档是**纯白**，
    /// 与 owner 要的「近乎不透明的浅灰」不符。
    /// ⛔ 不写十六进制色值：颜色唯一来源是语义系统色 / `AppTheme`。
    static let base: UIColor = .secondarySystemBackground

    /// 0.92 —— 底色的不透明度。叠在 `.regularMaterial` 之上 ⇒ 合计约 98% 不透明，
    /// 即 owner 说的「近乎不透明」；剩下那约 8% 只透出材质纹理，
    /// 不足以让正文底色（米黄 / 护眼绿 / 纯黑）把面板染回去。
    static let baseOpacity: CGFloat = 0.92

    /// 边缘线不透明度：浅色面板用深色线（0.14）、深色面板用浅色线（0.12）。
    ///
    /// 取值与旧版**逐值相同**，变的只是判据：从「正文底色」换成「**面板底色**」。
    /// 面板已不随正文变化，若还按正文判，「深色外观 + 米黄正文」会出现「深色面板 + 黑线」
    /// —— 线压在面板上等于看不见。0.14 正是旧版浅色默认主题（正文 #F2F2F7，
    /// 亮度 ≈ 0.951 > 旧的近纯白档 0.92）实际在用的那一档 ⇒ 默认观感零变化。
    /// 旧的「近纯白 0.14」独立档已并入浅色档：面板底色在同一外观下是常量，
    /// 不再存在「比近纯白更白」的第二种浅色面板可供分档。
    static let darkEdgeOpacity: CGFloat = 0.12
    static let lightEdgeOpacity: CGFloat = 0.14

    /// 0.15 —— 阴影不透明度。**一套值，不分明暗**。
    ///
    /// ## 为什么不再分档
    /// 旧版 深色 0.30 / 近纯白 0.13 / 浅色 0.10 三档是「跟随正文底色」的产物（正文越白，
    /// 影子越淡），已随正文一起删除。系统 elevation 阴影本身基本不随明暗外观变化
    /// —— 同一个浮层在浅色与深色下用的是同一条影。
    ///
    /// ## 为什么 0.15 读起来像系统影
    /// 系统 elevation 阴影的三个特征：**黑基**、**低不透明度**（约 0.10–0.18）、
    /// **半径明显大于偏移**（`shadowRadius` 12 : `shadowOffsetY` 5 ≈ 2.4 : 1 ⇒ 宽而淡）。
    /// 0.15 取这条带的中间值；它也只比旧版浅色默认主题的 0.13 高 0.02
    /// ⇒ 不会变成自造的浓影。
    ///
    /// 真机若觉得面板浮不起来，**只调这一个数**（0.15 → 0.18 即可，别加到 0.3）。
    static let shadowOpacity: CGFloat = 0.15

    /// 12 —— 投影半径。比旧版的 10 大一档：系统 elevation 的影是「宽而淡」，
    /// 半径偏大 + 不透明度偏低属于同一套语言（只提不透明度、半径不动会读成硬描边）。
    static let shadowRadius: CGFloat = 12

    /// 按 traits 解析出的面板底色 —— 边缘线与前景色都从它出发（同一套 traits，不各算各的）。
    static func resolvedBase(traits: UITraitCollection) -> UIColor {
        base.resolvedColor(with: traits)
    }

    /// 染色层 = 面板底色 + 不透明度（叠在材质之上的那一层）。
    static func tint(traits: UITraitCollection) -> UIColor {
        resolvedBase(traits: traits).withAlphaComponent(baseOpacity)
    }

    /// 边缘线颜色：**朝正文那一侧**的那根 0.5pt 细线。
    ///
    /// 为什么用 `UIColor.black` / `.white` 而不是 `AppTheme` 的语义色：
    /// 这根线要跟**面板自身**的明暗走，而 `UIColor.label` 这类语义色跟的是应用外观
    /// —— 面板底色虽也按外观取，但「语义色的亮度」不等于「面板色的亮度」，
    /// 直接按面板色的亮度选黑 / 白，线与面板的对比度才有保证。
    static func edge(for panel: UIColor) -> UIColor {
        panel.isLightBackground
            ? UIColor.black.withAlphaComponent(lightEdgeOpacity)
            : UIColor.white.withAlphaComponent(darkEdgeOpacity)
    }

    /// 阴影色：恒为黑 —— 影子是「遮光」，浅色与深色面板共用同一条黑影（见 `shadowOpacity`）。
    /// 白影会变成发光，不用。
    static func shadow() -> UIColor {
        UIColor.black.withAlphaComponent(shadowOpacity)
    }

    /// 前景色（图标 / 章节标题 / 下栏文字）：按**面板底色**的亮度选黑 / 白。
    ///
    /// ## 判据本身没有新增
    /// 仍走全仓唯一那条「背景上的文字 / 图标用什么颜色」的规则
    /// `ReadingTextColorMode.automatic.uiColor(on:custom:)` ⇒ 同一个 `UIColor.isLightBackground`、
    /// 同一个 **0.6** 阈值（`ReaderAppearance.swift`）。改的只有喂进去的那个「背景」：
    /// 从正文底色换成图标**实际坐着的那层系统底色**。
    ///
    /// ## 为什么喂「底色」而不是「底色 + 0.92 alpha」
    /// alpha 只让面板透出一点材质纹理，不改变它相对 0.6 阈值的位置
    /// （#F2F2F7 亮度 ≈ 0.951、#1C1C1E ≈ 0.111，离阈值都很远）⇒ 两者结论恒等。
    ///
    /// ## 为什么还要 `traits`
    /// 调用点（`ReaderChromeStyle.make(page:)`）拿不到可靠的 `UITraitCollection.current`
    /// —— 那个值在派生上下文里并不可靠（理由同 `ReadingTextColorMode.automatic` 的注释）。
    /// 这里用**同一套** traits 显式解析，得到的才是可直接交给 SwiftUI 的静态黑 / 白。
    static func foreground(for panel: UIColor, traits: UITraitCollection) -> UIColor {
        ReadingTextColorMode.automatic.uiColor(on: panel, custom: .defaultCustomText)
            .resolvedColor(with: traits)
    }
}

// MARK: - 样式

/// 控制栏的一套视觉令牌：玻璃（系统材质 + 系统语义底色）、边缘线、投影、前景色。
///
/// ## 为什么仍是「派生」令牌
/// 底色是系统语义色，但**边缘线 / 阴影 / 前景色仍要从它派生**：同一块底色在浅色外观下
/// 要配黑线黑字、在深色外观下要配白线白字，而这个结论必须与底色**在同一套 traits 下**算出来。
///
/// ## 为什么颜色都是动态色
/// 底色本身是动态色（`secondarySystemBackground` 的浅 / 深两版），而 `UIColor.getRed`
/// 解析动态色用的是 `UITraitCollection.current` —— 在阅读页 `.preferredColorScheme`
/// 强制外观时并不可靠。所以这里与 `ReadingTextColorMode.automatic` 同一手法：
/// 把「按 traits 解析 → 派生」整段包进 `UIColor { traits in ... }`，
/// 让底色与派生色**在同一套 traits 下**一起解析。
struct ReaderChromeStyle {
    var material: Material
    var tint: Color
    var edgeColor: Color
    var shadowColor: Color
    var shadowRadius: CGFloat
    /// 图标 / 章节标题 / 下栏文字的**前景色**。
    ///
    /// 按**面板底色**（`ReaderChromeDerivation.base`）的亮度选黑 / 白 ——
    /// 理由见 `ReaderChromeDerivation.foreground(for:traits:)`。
    var foreground: Color

    /// 控制栏样式。
    ///
    /// ⚠️ **`page` 参数已不参与任何派生**：面板改成系统颜色后，底色 / 边缘线 / 阴影 / 前景色
    /// 全都只看明暗外观（traits）。签名**刻意保留** —— 唯一调用点在
    /// `ReaderView.swift`（`ReaderChromeStyle.make(page: pageColor)`），那个文件不在本次改动范围内，
    /// 保留参数比改签名安全。参数写成 `page _:` 只是把「**故意不使用**」写进代码
    /// （SwiftFormat 的 `unusedArguments` 也要求如此），**外部标签 `page:` 逐字未变**
    /// ⇒ 调用点一个字节都不用改。正文底色仍由 `ReaderView.pageBackgroundColor(for:)` 提供
    /// （正文铺底与角落 HUD 还要用），只是不再喂给这里。
    ///
    /// - 前景色刻意用 `.automatic`（而不是用户在阅读设置里选的 `textColorMode`）：
    ///   控制栏的图标 / 标题压在**面板底色**上，必须跟随外观明暗；用户自定义正文色是给正文用的，
    ///   压在这层面板上可能直接不可读。
    static func make(page _: UIColor) -> ReaderChromeStyle {
        ReaderChromeStyle(
            material: ReaderChromeDerivation.material,
            tint: Color(uiColor: UIColor { traits in
                ReaderChromeDerivation.tint(traits: traits)
            }),
            edgeColor: Color(uiColor: UIColor { traits in
                ReaderChromeDerivation.edge(for: ReaderChromeDerivation.resolvedBase(traits: traits))
            }),
            shadowColor: Color(uiColor: ReaderChromeDerivation.shadow()),
            shadowRadius: ReaderChromeDerivation.shadowRadius,
            foreground: Color(uiColor: UIColor { traits in
                ReaderChromeDerivation.foreground(
                    for: ReaderChromeDerivation.resolvedBase(traits: traits),
                    traits: traits
                )
            })
        )
    }
}
