import NovelCore
import SwiftUI
import UIKit

// 阅读页控制栏（上栏 / 下栏）的玻璃背景、栏体、叠加层与转场。
//
// 从 `ReaderView.swift` 拆出来的：那个文件已贴近 SwiftLint `file_length` 600 的硬门
// （拆前 586 行），而控制栏是其中最大、最独立的一块。与 `ReaderView+PageTurn.swift`
// 同一处理：成员原本是 `private`（Swift 的 `private` 是本文件级的），拆文件后改为**模块内可见**。
//
// 颜色从哪来（染色 / 边缘 / 阴影 / 前景的派生规则、亮度阈值为什么是 0.6）在
// `ReaderView+ChromeStyle.swift`；本文件只管布局、玻璃叠法与转场。
//
// ## 视觉沿用 owner 的设计稿
// 玻璃 = 系统 `Material` + 主题染色（用 `mask` 做渐变羽化，贴近正文一侧略减淡）
// + 0.5pt 细边缘线（朝正文那一侧）+ 只向正文方向偏移的柔影；上栏 44pt「返回 / 居中标题 / 更多」、
// 下栏 49pt「图标 + 文字标签」（两个高度都是 `minHeight`：字号随 Dynamic Type 长大时栏与玻璃
// 一起变高）；玻璃向屏幕外延伸，内容留在安全区内。
//
// 条目**以项目既有能力为准**（owner：设计稿只是视觉参考）：
// 上栏 = 返回 + 居中标题 + 更多菜单；下栏 = 目录 / 下载 / 搜索 / 设置。
//
// ## 复用而不是另造
// 按下反馈用 `PressableCardButtonStyle`（§2.9 优先复用，不另造第二个按下样式）；
// 通用间距 / 圆角取 `DesignTokens`，控制栏专有的尺度收在 `ReaderChromeMetrics`。

// MARK: - 边

/// 控制栏贴屏幕的哪一条边：上下两栏共用同一套玻璃 / 转场逻辑，只有方向不同。
private enum ReaderChromeEdge {
    case top
    case bottom

    /// 贴近正文的一侧（上栏朝下、下栏朝上）—— 边缘线、羽化渐变、投影都朝这一侧。
    var contentAnchor: Alignment {
        self == .top ? .bottom : .top
    }

    /// 玻璃向屏幕外延伸的那条边：上栏铺到状态栏 / 灵动岛之下，下栏铺到 Home Indicator 之下。
    /// 铺出去的**只有玻璃**；栏内内容仍留在安全区内（见 `ReaderChromeOverlay`）。
    var bleedingEdge: Edge.Set {
        self == .top ? .top : .bottom
    }

    /// 投影**只**向正文方向偏移（上栏向下、下栏向上）；贴屏幕的另三边被屏幕裁掉 ⇒ 单侧柔影。
    var shadowOffsetY: CGFloat {
        self == .top ? ReaderChromeMetrics.shadowOffsetY : -ReaderChromeMetrics.shadowOffsetY
    }

    /// 呼出 / 隐藏时从哪一侧轻微滑入（上栏自上 8pt、下栏自下 8pt）。
    var enterOffsetY: CGFloat {
        self == .top ? -ReaderChromeMetrics.enterOffsetY : ReaderChromeMetrics.enterOffsetY
    }
}

// MARK: - 尺度常量

/// 控制栏专有的尺度常量（**有名字、带推导**，不散落成魔数）。
///
/// 通用间距 / 圆角一律取 `DesignTokens`；这里只放「控制栏专有」的那些值 ——
/// 它们要么来自 HIG 的栏高，要么从命中区几何推导出来。
private enum ReaderChromeMetrics {
    /// 44 —— 导航栏标准高度（HIG）。上栏只有一行「图标 + 居中标题」，
    /// 与系统导航栏等高 ⇒ 进出阅读页 / 换页时不会与导航栏的观感打架。
    ///
    /// ⚠️ 它是 `minHeight` 而不是固定高度（见 `ReaderTopBar.body`）：栏内字号随 Dynamic Type
    /// 长大时，栏跟着内容一起变高（默认内容尺寸下正好 44），不会把图标 / 标题裁在栏外。
    static let topBarHeight: CGFloat = 44

    /// 49 —— 标签栏标准高度（HIG）。下栏条目比上栏多一行文字标签，故比上栏高 5pt（44 + 5 = 49），
    /// 与系统标签栏等高。
    ///
    /// ⚠️ 同样只作 `minHeight`：AX 大字号下条目（图标 + 文字）撑高，栏与玻璃背景一起变高
    /// （默认内容尺寸下正好 49）。
    static let bottomBarHeight: CGFloat = 49

    /// 44 —— 触控目标下限（HIG §9）。图标本身远小于此，命中区必须补足，
    /// 否则「看得见点不着」。
    static let minTouchTarget: CGFloat = 44

    /// 0.35 —— 到边界时（首章没有上一章 / 末章没有下一章）跳章按钮的**置灰**不透明度。
    ///
    /// 只挂 `.disabled(true)` 不够：本项目按钮走**自定义** `ButtonStyle`，系统不会替它降级外观，
    /// 不显式调透明度就会「看着能点、点下去没反应」。0.35 取系统禁用态的量级
    /// （栏内其他图标是一眼可分的实色），且它与 `.disabled` 叠加给出**两条**线索：
    /// 亮度整体下降（看得见）+ VoiceOver 播报「不可用」（听得见）。
    static let disabledOpacity: Double = 0.35

    /// 8 —— 栏内左右内边距（`DesignTokens.Spacing.xs`）：按钮自身已带 44pt 命中区，
    /// 这里只留「图标不贴屏幕边」的呼吸量。
    static let horizontalPadding = DesignTokens.Spacing.xs

    /// 56 —— 居中标题**左右各**预留的宽度 = 按钮命中区 44 + 栏内边距 8 + 视觉间隙 4。
    /// 不留这两段，长章节名会顶到两侧按钮上；留了之后标题只会**尾部截断**。
    static let titleSideReserve: CGFloat = 56

    /// 0.5 —— 贴正文那一侧的边缘线高度：发丝级（@2x 恰好 1 物理像素）。
    /// 目的是「让轮廓自然显现」，不是描边。
    static let edgeLineHeight: CGFloat = 0.5

    /// 5 —— 投影向正文方向的偏移量：只朝正文扩散、其余三边被屏幕裁掉，
    /// 形成轻微悬浮感而不是一圈黑边。
    static let shadowOffsetY: CGFloat = 5

    /// 8 —— 呼出 / 隐藏时的滑入位移：够看出「从上下进来」，又不至于像整块飞入。
    static let enterOffsetY: CGFloat = 8

    /// 0.22 —— 控制栏呼出 / 隐藏的动画时长（设计稿给的缓动时长）。
    /// 转场是「淡入 + 8pt 位移」，用缓出比弹簧更贴合（位移是单向的，没有可回弹的惯性）。
    static let toggleDuration: Double = 0.22

    /// 羽化遮罩的两个停点：从栏内满染，到贴近正文一侧淡到 0.78 —— 软化「玻璃 / 正文」的硬切。
    static let featherFullLocation: CGFloat = 0.72
    static let featherEndOpacity = 0.78

    /// 栏内图标字体：`.body`（默认内容尺寸下 17pt）随 Dynamic Type 缩放。
    ///
    /// 设计稿给的是 `font(.system(size: 18))` 固定字号 —— 项目**全仓不用固定字号**
    /// （固定字号在大字号无障碍设置下会被固定栏高裁掉），故用最接近的文本样式承接；
    /// 17 与 18 的差别在图标上不可辨。
    static let iconFont: Font = .body.weight(.medium)

    /// 1.35 —— `chevron.left` 的**光学补偿**缩放：只作用在上栏的返回箭头上
    /// （经 `ReaderTopBar.iconButton` 传给文件作用域的 `chromeIconLabel`）。
    ///
    /// ## 为什么需要
    /// `chevron.left`（细折线箭头）与 `ellipsis.circle`（外圆铺满字身）用**同一个** `iconFont` 时，
    /// 墨迹高度天生不同 —— 字号一样，右边的圆圈看着明显更大。
    ///
    /// ## 1.35 的推导（⚠️ **估算值，需真机复核**）
    /// - SF Pro 的 cap height ≈ **0.70 em**（capHeight 1443 / unitsPerEm 2048 ≈ 0.705）；
    /// - `ellipsis.circle` 这类**圆形外框**符号按 cap height 绘制 ⇒ 墨迹高 ≈ 0.70 em；
    /// - `chevron.left` 是细折线，墨迹高约在 x-height 量级 ⇒ 约 **0.52 em**
    ///   （SF Pro x-height 1062 / 2048 ≈ 0.52）；
    /// - 0.70 / 0.52 ≈ **1.346** ⇒ 取 **1.35**。
    ///
    /// ⚠️ **这两个墨迹比值没有官方数据**：SF Symbols 只公开 bounding box、不公开每个符号的
    /// 墨迹（ink）框，Apple 也没公布「圆形符号按 cap height 绘制」这条规则 ——
    /// 上面两条是照 SF Pro 的字体度量 + 符号与文字对齐的通行做法**估**出来的。
    /// 真机上若仍能看出大小差，**只改这一个数**（这正是把它收成命名常量而不是魔数的原因）。
    ///
    /// ## Dynamic Type 下**不漂移**
    /// `scaleEffect` 是**乘在文本样式之后**的固定比例：`.body` 先随 Dynamic Type 缩放，
    /// 箭头再乘 1.35 ⇒ 两个图标在任何字号档位都保持 1.35 的墨迹高比。
    /// （没选「给箭头换更大的文本样式（如 `.title3`）」正是因为它与 `.body` 的**缩放曲线不同**，
    /// 默认字号下勉强对齐、AX 大字号下比例会漂移。）
    ///
    /// ## 与 44pt 命中区的关系
    /// `scaleEffect` 是纯视觉变换，**不改变布局尺寸** —— 命中区仍是 `minTouchTarget`(44×44)。
    /// 放大后的箭头墨迹（约 0.52 × 17pt × 1.35 ≈ 12pt 高）仍远在 44pt 命中区之内。
    static let chevronOpticalScale: CGFloat = 1.35

    /// 下栏文字标签字体：`.caption2` 在默认内容尺寸下正好 **11pt**（HIG 标签栏文字标准），
    /// 且随 Dynamic Type 缩放 —— 同样是对设计稿固定 11pt 的「换成文本样式」适配。
    static let labelFont: Font = .caption2

    /// 按下反馈：复用项目既有的 `PressableCardButtonStyle`。
    /// - `pressedScale: 0.97`：栏内按钮命中区 44pt，比卡片小，缩放幅度比卡片的 0.98 略大一档才可感知；
    /// - `shape`：强调层贴按钮自身的 `Radius.sm`(12) 圆角。栏是**通栏玻璃**（不再是一个大圆角面板），
    ///   按钮不再被父容器圆角裁切，故用卡片默认的 `sm` 而不是 `Radius.xs`。
    static let buttonStyle = PressableCardButtonStyle(
        pressedScale: 0.97,
        shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
    )
}

// MARK: - 图标按钮的 label（唯一构建处）

/// 控制栏**图标按钮 label** 的唯一构建处：上栏的「返回 / 更多」与下栏上方的「上一章 / 下一章」
/// 全部走它 —— 字体、光学补偿、44pt 命中区、`contentShape`、无障碍标签的施加方式**只有这一处**。
///
/// - `systemImage`：SF Symbol 名。
/// - `a11yLabel`：无障碍标签。施加在 **label** 上而不是各控件上：`Button` / `Menu` 都会聚合
///   自身 label 的无障碍信息，两种写法等效，写在 label 上才能做到「只有一处」。
/// - `opticalScale`：抹平符号**墨迹大小**的先天差异，只给细箭头传非 1 值，
///   取值与推导见 `ReaderChromeMetrics.chevronOpticalScale`。默认 1 = 不补偿。
private func chromeIconLabel(
    _ systemImage: String,
    a11yLabel: String,
    opticalScale: CGFloat = 1
) -> some View {
    Image(systemName: systemImage)
        .font(ReaderChromeMetrics.iconFont)
        .scaleEffect(opticalScale)
        .frame(
            minWidth: ReaderChromeMetrics.minTouchTarget,
            minHeight: ReaderChromeMetrics.minTouchTarget
        )
        .contentShape(Rectangle())
        .accessibilityLabel(a11yLabel)
}

// MARK: - 玻璃背景

/// 通栏玻璃背景：系统材质 + 主题染色（带羽化）+ 0.5pt 细边缘线 + 只朝正文方向的柔影。
private struct ReaderChromeGlass: View {
    let style: ReaderChromeStyle
    let edge: ReaderChromeEdge

    var body: some View {
        ZStack {
            Rectangle().fill(style.material)
            Rectangle()
                .fill(style.tint)
                .mask(featherMask)
        }
        .overlay(alignment: edge.contentAnchor) {
            Rectangle()
                .fill(style.edgeColor)
                .frame(height: ReaderChromeMetrics.edgeLineHeight)
        }
        // 先合成成一层再投影：否则投影会分别落在材质 / 染色 / 边缘线上，接缝处出现重影。
        .compositingGroup()
        .shadow(color: style.shadowColor, radius: style.shadowRadius, x: 0, y: edge.shadowOffsetY)
    }

    /// 内侧羽化遮罩：从栏内满染淡到贴近正文处 0.78。
    /// （遮罩只看 alpha，`.white` 在这里只是「全不透明」的写法，不参与配色。）
    private var featherMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: ReaderChromeMetrics.featherFullLocation),
                .init(color: .white.opacity(ReaderChromeMetrics.featherEndOpacity), location: 1),
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
    }
}

// MARK: - 上栏

/// 上栏：返回 · 章节名（居中、单行、尾部截断）· 更多菜单。
///
/// 「更多」是项目既有的入口（U9-6 把原来的 `eye.slash` 换成了 `ellipsis.circle`），
/// 菜单**内容原样保留**：里面仍是一条置灰的「更多选项待添加」占位项，本轮不动它
/// —— 留一条不可点的占位项而不是空 `Menu`，因为空菜单点开是一片空白，
/// 用户会以为控件坏了（§11 反馈：别给一个点了没反应的入口）。
private struct ReaderTopBar: View {
    let title: String
    let style: ReaderChromeStyle
    var onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(style.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ReaderChromeMetrics.titleSideReserve)

            HStack(spacing: 0) {
                iconButton(
                    "返回",
                    systemImage: "chevron.left",
                    opticalScale: ReaderChromeMetrics.chevronOpticalScale,
                    action: onBack
                )
                Spacer(minLength: 0)
                moreMenu
            }
            .foregroundStyle(style.foreground)
        }
        .buttonStyle(ReaderChromeMetrics.buttonStyle)
        // `minHeight`（不是固定高度）：字号随 Dynamic Type 长大时栏跟着长，
        // 玻璃背景挂在栏上，因此也一起变高；默认内容尺寸下仍是 HIG 的 44pt。
        .frame(minHeight: ReaderChromeMetrics.topBarHeight)
        .padding(.horizontal, ReaderChromeMetrics.horizontalPadding)
        .frame(maxWidth: .infinity)
        .background {
            // 玻璃铺到状态栏 / 灵动岛之下；按钮与标题仍留在安全区内（见 `ReaderChromeOverlay`）。
            ReaderChromeGlass(style: style, edge: .top)
                .ignoresSafeArea(edges: ReaderChromeEdge.top.bleedingEdge)
        }
    }

    /// 图标按钮：视觉图标可小于 44pt，命中区按 HIG 补足。
    /// label 与 `moreMenu`（以及下栏上方的跳章按钮）**共用** `chromeIconLabel` —— 字体、
    /// 光学补偿、44pt 命中区、`contentShape`、无障碍标签的施加方式只有那一处，两侧不会漂移。
    private func iconButton(
        _ label: String,
        systemImage: String,
        opticalScale: CGFloat = 1,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chromeIconLabel(systemImage, a11yLabel: label, opticalScale: opticalScale)
        }
    }

    /// 右上角「更多」菜单。命中区与按下反馈与左侧返回按钮**逐值一致**：
    /// 同一个 `chromeIconLabel`（⇒ 同一个 44pt 命中区 / `contentShape` / 字体 / 无障碍施加方式）、
    /// 同一个 `PressableCardButtonStyle`。
    ///
    /// 菜单**内容原样保留**（一条置灰的占位项），不换成别的控件 —— 本轮只统一外观与命中区。
    private var moreMenu: some View {
        Menu {
            Button("更多选项待添加") {}
                .disabled(true)
        } label: {
            chromeIconLabel("ellipsis.circle", a11yLabel: "更多")
        }
        // 显式再挂一次按下反馈。外层 `ZStack` 已经把**同一个** `buttonStyle` 注入环境，
        // 所以「`Menu` 读环境里的 `ButtonStyle`」时这一句是等价重复（无副作用）；
        // 而万一 `Menu` 的 label 走自己的 `MenuStyle` 样式链、不读环境里的 `ButtonStyle`，
        // 这里就是唯一可能生效的挂点 —— 故显式写上，不依赖外层那一次。
        //
        // ⚠️ **未验证**：本机没有 Xcode / 模拟器，无法确认 `Menu` 是否吃 `ButtonStyle`。
        // 若真机上「更多」按下仍无强调层，下一步是给 `Menu` 的 label 自绘按下态，
        // **不换控件**（`Menu` 承载既有「更多」入口）。
        .buttonStyle(ReaderChromeMetrics.buttonStyle)
    }
}

// MARK: - 章节跳转条

/// 下栏**正上方**的章节跳转条：左端「上一章」、右端「下一章」，中间留空。
///
/// ## 几何
/// - **宽度**：与上栏 / 下栏同宽 —— 三者都在 `ReaderChromeOverlay` 的同一个 `VStack` 里，
///   共用同一份左右安全区内缩与 `ReaderChromeMetrics.horizontalPadding`。
/// - **高度**：`minTouchTarget`(44)，与上栏等高。**是 `minHeight` 不是固定高度**：
///   Dynamic Type 长大时条与玻璃一起变高（与上下栏同一处理）。
/// - **位置**：紧贴下栏上方，中间留 `DesignTokens.Spacing.xs`(8pt) 的空隙 ——
///   两条玻璃**各自独立**（各有自己的 0.5pt 边缘线与柔影），8pt 间隙让「这是另一条」一眼可辨；
///   两条的玻璃语言逐值同源（都走 `ReaderChromeGlass`）。
///
/// ## 为什么用 `edge: .bottom`
/// 本条的内容（图标）在条**上方**，与下栏同侧 ⇒ 用同一条边语义：边缘线朝上、
/// 柔影向上扩散、羽化朝上淡出。刻意**不**加 `.ignoresSafeArea`：这条玻璃不贴屏幕边，
/// 只在安全区内浮着（铺到屏幕外的只有上栏与下栏）。
///
/// ## 显隐
/// 本视图**没有**自己的显隐开关：它装在 `ReaderChromeOverlay` 里，由 `ReaderView.body` 那一个
/// `if isChromeVisible` 与上下栏一起进出 ⇒ 「跟控制栏一起显隐」在结构上无法分叉。
/// 它是叠加层的一部分，**不占正文布局**：显隐不改变正文分页与阅读位置。
///
/// ## 符号选择
/// `backward.end` / `forward.end`（上一首 / 下一首的通用字形）而不是 `chevron.left/right`：
/// 一是上栏的「返回」已经占用 `chevron.left`，重复会让两个不同动作长得一样；
/// 二是这两个符号的墨迹铺满字身（实心三角 + 竖条），不会重演上栏「细箭头看着小」的问题，
/// 左右互为镜像 ⇒ 两者之间**不需要**光学补偿。
private struct ReaderChapterJumpBar: View {
    let style: ReaderChromeStyle
    /// 相邻章节；`nil` = 到边界（首章的上一章 / 末章的下一章），对应按钮置灰。
    let previousChapter: ChapterItem?
    let nextChapter: ChapterItem?
    var onJumpToChapter: (ChapterItem) -> Void

    var body: some View {
        HStack(spacing: 0) {
            jumpButton("上一章", systemImage: "backward.end", chapter: previousChapter)
            Spacer(minLength: 0)
            jumpButton("下一章", systemImage: "forward.end", chapter: nextChapter)
        }
        .buttonStyle(ReaderChromeMetrics.buttonStyle)
        .foregroundStyle(style.foreground)
        .frame(minHeight: ReaderChromeMetrics.minTouchTarget)
        .padding(.horizontal, ReaderChromeMetrics.horizontalPadding)
        .frame(maxWidth: .infinity)
        .background {
            ReaderChromeGlass(style: style, edge: .bottom)
        }
    }

    /// 单侧跳章按钮。`chapter == nil` ⇒ 到边界：`.disabled(true)` + 置灰（见 `disabledOpacity`）。
    ///
    /// `.disabled` 同时做三件事：命中测试关掉（不会「看着灰还能点」）、
    /// VoiceOver 播报「不可用」、自定义 `ButtonStyle` 不再收到按下事件 ⇒ 不会有按下反馈。
    private func jumpButton(
        _ label: String,
        systemImage: String,
        chapter: ChapterItem?
    ) -> some View {
        Button {
            guard let chapter else { return }
            onJumpToChapter(chapter)
        } label: {
            chromeIconLabel(systemImage, a11yLabel: label)
        }
        .disabled(chapter == nil)
        .opacity(chapter == nil ? ReaderChromeMetrics.disabledOpacity : 1)
    }
}

// MARK: - 下栏

/// 下栏：目录 · 下载 · 搜索 · 设置（图标 + 11pt 文字标签，等分栏宽）。
///
/// 条目以**项目既有能力**为准（owner：「依照原样，项目代码只是参考，下栏依次为目录，下载搜索设置」）：
/// 目录 / 搜索 / 设置各打开既有 sheet，下载调既有 `downloadCurrentChapter`。
/// 设计稿的「主题 / 字号 / 书签」不采用：「主题」「字号」都已收在设置 sheet 里，
/// 「书签」项目**没有数据模型**（要做需先加 Bookmark 模型与存储，本任务不做）。
private struct ReaderBottomBar: View {
    let style: ReaderChromeStyle
    var onContents: () -> Void
    var onDownload: () -> Void
    var onSearch: () -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            item("目录", systemImage: "list.bullet", action: onContents)
            item("下载", systemImage: "arrow.down.circle", action: onDownload)
            item("搜索", systemImage: "magnifyingglass", action: onSearch)
            item("设置", systemImage: "textformat.size", action: onSettings)
        }
        .buttonStyle(ReaderChromeMetrics.buttonStyle)
        .foregroundStyle(style.foreground)
        // 与上栏同理：`minHeight` —— AX 大字号下条目撑高、栏与玻璃一起变高，
        // 默认内容尺寸下仍是 HIG 的 49pt。
        .frame(minHeight: ReaderChromeMetrics.bottomBarHeight)
        .padding(.horizontal, ReaderChromeMetrics.horizontalPadding)
        .frame(maxWidth: .infinity)
        .background {
            // 玻璃铺到 Home Indicator 之下；条目仍留在安全区内。
            ReaderChromeGlass(style: style, edge: .bottom)
                .ignoresSafeArea(edges: ReaderChromeEdge.bottom.bleedingEdge)
        }
    }

    private func item(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: systemImage)
                    .font(ReaderChromeMetrics.iconFont)
                Text(title)
                    .font(ReaderChromeMetrics.labelFont)
            }
            .frame(maxWidth: .infinity, minHeight: ReaderChromeMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}

// MARK: - 叠加层

/// 控制栏叠加层：上栏贴顶、下栏贴底，**浮在正文之上、不参与正文布局**。
///
/// ## 为什么必须是叠加层（设计稿明确要求）
/// 呼出 / 隐藏控制栏**不能**改变正文的分页与阅读位置。它作为 `ZStack` 里与正文并列的一层
/// （见 `ReaderView.body`），自己不占正文的布局空间；玻璃再靠 `.ignoresSafeArea(edges:)`
/// 铺出安全区 —— 正文层一行都不动（`readerContentPaddings` / `readerContentSize` 未改）。
///
/// ## 内容留在安全区内
/// 铺到屏幕外的**只有玻璃**：栏内内容按传入的安全区 `padding` 内缩，
/// 所以标题 / 图标永远落在灵动岛、Home Indicator 之外。
struct ReaderChromeOverlay: View {
    let style: ReaderChromeStyle
    let chapterTitle: String
    /// 当前安全区（由 `ReaderView` 的 `GeometryReader` 提供）。
    let safeAreaInsets: EdgeInsets
    /// 相邻章节（`ReaderFeature.State` 的派生属性）：`nil` = 到边界，跳章条据此置灰。
    let previousChapter: ChapterItem?
    let nextChapter: ChapterItem?

    var onBack: () -> Void
    var onContents: () -> Void
    var onDownload: () -> Void
    var onSearch: () -> Void
    var onSettings: () -> Void
    /// 跳章：上一章 / 下一章**共用**一个闭包（两侧都走既有的 `loadChapterWithName` 正常加载路径）。
    var onJumpToChapter: (ChapterItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ReaderTopBar(
                title: chapterTitle,
                style: style,
                onBack: onBack
            )
            .padding(.top, safeAreaInsets.top)
            .transition(.chromeBar(edge: .top, reduceMotion: reduceMotion))

            Spacer(minLength: 0)

            // 章节跳转条：贴在下栏上方 8pt（`DesignTokens.Spacing.xs`）。
            // 转场与下栏同向（自下 8pt 滑入）：它与下栏是一起从屏幕底部进来的。
            ReaderChapterJumpBar(
                style: style,
                previousChapter: previousChapter,
                nextChapter: nextChapter,
                onJumpToChapter: onJumpToChapter
            )
            .padding(.bottom, DesignTokens.Spacing.xs)
            .transition(.chromeBar(edge: .bottom, reduceMotion: reduceMotion))

            ReaderBottomBar(
                style: style,
                onContents: onContents,
                onDownload: onDownload,
                onSearch: onSearch,
                onSettings: onSettings
            )
            .padding(.bottom, safeAreaInsets.bottom)
            .transition(.chromeBar(edge: .bottom, reduceMotion: reduceMotion))
        }
        .padding(.leading, safeAreaInsets.leading)
        .padding(.trailing, safeAreaInsets.trailing)
        // 三条栏各自带方向相反的转场；容器自己不再叠一层淡入，否则淡入会叠成两层。
        .transition(.identity)
    }
}

// MARK: - 转场

private extension AnyTransition {
    /// 控制栏呼出 / 隐藏的转场：淡入 + 轻微位移（上栏自上 8pt、下栏自下 8pt）。
    ///
    /// Reduce Motion 时**只做淡入**：位移是前庭刺激，降级 ≠ 无反馈 —— 淡入仍在。
    static func chromeBar(edge: ReaderChromeEdge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(x: 0, y: edge.enterOffsetY))
    }
}

// MARK: - 与 ReaderView 的接线

extension ReaderView {
    /// 阅读页**正文底色**的唯一来源（正文层与上下栏的玻璃都用它）。
    ///
    /// 返回 `UIColor` 而不是 `Color`：控制栏要拿它去**解析明暗**并派生玻璃，
    /// 而 `Color` 包一层就取不到分量（`UIColor(Color)` 还会把动态色解析成当时的静态值）。
    ///
    /// 原先叫 `backgroundColor(for:)` 且是 `private`：Swift 的 `private` 是本文件级的，
    /// 控制栏拆到本文件后取不到，故随控制栏一起搬过来并改为模块内可见
    /// （与 `ReaderView+PageTurn.swift` 放开 `reduceMotion` 同一处理）。
    func pageBackgroundColor(for configuration: PaginationConfiguration) -> UIColor {
        configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor,
            customDark: configuration.customBackgroundColorDark
        )
    }

    /// 控制栏呼出 / 隐藏的**唯一**动画曲线。
    ///
    /// 曲线只在这里定义一次：`setChromeVisible` 是显隐的唯一写入口，
    /// 中央点击、下载完成后自动隐藏都走它，不在多个调用点各写一遍。
    /// Reduce Motion 时返回 `nil` ⇒ 不加动画（转场本身也已退化为纯淡入）。
    static func chromeToggleAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: ReaderChromeMetrics.toggleDuration)
    }
}
