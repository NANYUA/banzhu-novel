import NovelCore
import SwiftUI
import UIKit

// 阅读页控制栏（上栏 / 下栏 / 章节跳转条）的玻璃背景、面板体、叠加层与转场。
//
// 从 `ReaderView.swift` 拆出来的：那个文件已贴近 SwiftLint `file_length` 600 的硬门
// （拆前 586 行），而控制栏是其中最大、最独立的一块。与 `ReaderView+PageTurn.swift`
// 同一处理：成员原本是 `private`（Swift 的 `private` 是本文件级的），拆文件后改为**模块内可见**。
//
// ⚠️ 本文件此后**又拆过一次**：章节跳转条 `ReaderChapterJumpBar` 连同它的文档注释搬到了
// `ReaderView+ChromeJumpBar.swift`（新增「本章页码进度条」后本文件会越过 600 行）——
// 同样是为 `file_length`；`ReaderChromeEdge` / `ReaderChromeMetrics` / `chromeIconLabel` /
// `ReaderChromeGlass` 因此放开为模块内可见（各自声明处都写了一行理由）。
//
// 颜色从哪来（染色 / 边缘 / 阴影 / 前景的派生规则、亮度阈值为什么是 0.6）在
// `ReaderView+ChromeStyle.swift`；本文件只管布局、玻璃叠法与转场。
//
// ## 结构：圆角浮动面板（不是通栏玻璃条）
// 上栏 / 下栏 / 跳章条都是**浮在正文之上的圆角面板**：左右各留 `Spacing.md`(16) 边距、
// 不贴屏幕上下边，形状是 `RoundedRectangle(cornerRadius: Radius.lg)`。
// 竖向位置由 `ReaderChromeOverlay` 的三段 `padding` 决定（上栏吃
// `ReaderView.topBarPadding(safeAreaInsets:)`，下栏与跳章条各吃 `Spacing.xs`），
// 控制栏这一层**只吃横向安全区** —— 与「上一版」逐值一致（U9-7：两栏要能贴到屏幕上下边）。
//
// ## 玻璃语言（借参考实现的配色，不借它的布局）
// 玻璃 = 系统 `Material` + 系统语义底色（用 `mask` 做渐变羽化，贴近正文一侧略减淡）
// + 0.5pt 细边缘线（朝正文那一侧，随面板圆角裁切）+ 只向正文方向偏移的柔影。
//
// ## 条目**以项目既有能力为准**（owner：参考代码只是视觉参考）
// 上栏 = 返回 + 居中标题 + 更多菜单；下栏 = 目录 / 下载 / 搜索 / 设置（图标 + 文字标签）；
// 跳章条 = 上一章 / 下一章。
//
// ## 复用而不是另造
// 按下反馈用 `PressableCardButtonStyle`（§2.9 优先复用，不另造第二个按下样式）；
// 通用间距 / 圆角取 `DesignTokens`，控制栏专有的尺度收在 `ReaderChromeMetrics`。

// MARK: - 边

/// 面板贴近正文的哪一侧：三条面板共用同一套玻璃 / 转场逻辑，只有方向不同。
///
/// ⚠️ 不是 `private`：跳章条已拆到 `ReaderView+ChromeJumpBar.swift`，而 `private` 是
/// **文件级**的 —— 那边构造玻璃与转场时要传 `edge: .bottom`。
enum ReaderChromeEdge {
    case top
    case bottom

    /// 贴近正文的一侧（上栏朝下、下栏与跳章条朝上）—— 边缘线、羽化渐变、投影都朝这一侧。
    var contentAnchor: Alignment {
        self == .top ? .bottom : .top
    }

    /// 投影**只**向正文方向偏移（上栏向下、下栏与跳章条向上），横向不偏移。
    /// 面板不贴屏幕边 ⇒ 另三边**不再**被屏幕裁掉，靠 `x: 0` 保持左右两侧是对称柔影。
    var shadowOffsetY: CGFloat {
        self == .top ? ReaderChromeMetrics.shadowOffsetY : -ReaderChromeMetrics.shadowOffsetY
    }

    /// 呼出 / 隐藏时从哪一侧轻微滑入（上栏自上 8pt、下栏与跳章条自下 8pt）。
    var enterOffsetY: CGFloat {
        self == .top ? -ReaderChromeMetrics.enterOffsetY : ReaderChromeMetrics.enterOffsetY
    }
}

// MARK: - 尺度常量

/// 控制栏专有的尺度常量（**有名字、带推导**，不散落成魔数）。
///
/// 通用间距 / 圆角一律取 `DesignTokens`；这里只放「控制栏专有」的那些值 ——
/// 它们要么来自 HIG 的栏高，要么从命中区几何推导出来。
///
/// ⚠️ 不是 `private`：跳章条已拆到 `ReaderView+ChromeJumpBar.swift`，而 `private` 是
/// **文件级**的 —— 那边要读 `buttonStyle` / `barInnerPadding` / `panelVerticalPadding` /
/// `panelOuterMargin` / `disabledOpacity`，进度条还要读 `minTouchTarget`（44 的唯一来源）。
enum ReaderChromeMetrics {
    /// 44 —— 触控目标下限（HIG §9）。图标本身远小于此，命中区必须补足，
    /// 否则「看得见点不着」。
    ///
    /// 三条面板的**内容行**都以它作 `minHeight`（`chromeIconLabel` / 下栏的 `item`），
    /// 面板高度 = 内容行 + 上下各 12pt 内边距 ⇒ 默认内容尺寸下 44 + 24 = **68pt**，
    /// 字号随 Dynamic Type 长大时内容行变高、面板与玻璃一起变高（不会把图标裁在面板外）。
    static let minTouchTarget: CGFloat = 44

    /// 0.35 —— 到边界时（首章没有上一章 / 末章没有下一章）跳章按钮的**置灰**不透明度。
    ///
    /// 只挂 `.disabled(true)` 不够：本项目按钮走**自定义** `ButtonStyle`，系统不会替它降级外观，
    /// 不显式调透明度就会「看着能点、点下去没反应」。0.35 取系统禁用态的量级
    /// （栏内其他图标是一眼可分的实色），且它与 `.disabled` 叠加给出**两条**线索：
    /// 亮度整体下降（看得见）+ VoiceOver 播报「不可用」（听得见）。
    static let disabledOpacity: Double = 0.35

    /// 12 —— 面板的**竖向内边距**（`Spacing.sm`）：12 + 44pt 内容行 + 12 = **68pt**，
    /// 与「上一版」的圆角面板逐值相同。
    ///
    /// ⚠️ 用内边距而不是固定高度：字号随 Dynamic Type 长大时内容行变高，面板与玻璃一起长
    /// ——「栏高用 `minHeight` 语义」在这里由**内容撑开**兑现，不需要再写一个固定值。
    static let panelVerticalPadding = DesignTokens.Spacing.sm

    /// 16 —— 面板到屏幕左右边的留边（`Spacing.md`）：面板**浮在正文之上、不贴屏幕边**。
    static let panelOuterMargin = DesignTokens.Spacing.md

    /// 16 —— 上栏面板的横向内边距（`Spacing.md`，与「上一版」的上栏一致）。
    /// 上栏只有两个 44pt 命中区的图标按钮，留宽一点，标题两侧的呼吸量才够。
    static let topBarInnerPadding = DesignTokens.Spacing.md

    /// 12 —— 下栏与跳章条面板的横向内边距（`Spacing.sm`，与「上一版」的下栏一致）。
    ///
    /// 12 这个值还有一层几何关系：栏内按钮的强调层圆角取 `Radius.xs`(6)，
    /// 而 `6 = Radius.lg`(18) `−` 12 ⇒ 按钮四周内缩 12pt 后，按下时的强调层
    /// **完全**落在面板圆角之内（推导见 `DesignTokens.Radius.xs`）。
    static let barInnerPadding = DesignTokens.Spacing.sm

    /// 0.5 —— 贴正文那一侧的边缘线高度：发丝级（@2x 恰好 1 物理像素）。
    /// 目的是「让轮廓自然显现」，不是描边。
    static let edgeLineHeight: CGFloat = 0.5

    /// 5 —— 投影向正文方向的偏移量：只朝正文扩散，另一侧留对称的浅影，
    /// 形成轻微悬浮感而不是一圈黑边。
    static let shadowOffsetY: CGFloat = 5

    /// 8 —— 呼出 / 隐藏时的滑入位移：够看出「从上下进来」，又不至于像整块飞入。
    static let enterOffsetY: CGFloat = 8

    /// 0.22 —— 控制栏呼出 / 隐藏的动画时长（设计稿给的缓动时长）。
    /// 转场是「淡入 + 8pt 位移」，用缓出比弹簧更贴合（位移是单向的，没有可回弹的惯性）。
    static let toggleDuration: Double = 0.22

    /// 羽化遮罩的两个停点：从面板内满染，到贴近正文一侧淡到 0.78 —— 软化「玻璃 / 正文」的硬切。
    static let featherFullLocation: CGFloat = 0.72
    static let featherEndOpacity = 0.78

    /// 栏内图标字体：`.body`（默认内容尺寸下 17pt）随 Dynamic Type 缩放。
    ///
    /// 设计稿给的是 `font(.system(size: 18))` 固定字号 —— 项目**全仓不用固定字号**
    /// （固定字号在大字号无障碍设置下会被裁掉），故用最接近的文本样式承接；
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
    /// - `shape`：强调层贴按钮自身的 `Radius.xs`(6) 圆角 —— 面板是圆角 `Radius.lg`(18) 的容器，
    ///   栏内按钮四周内缩 12pt，故 `6 = 18 − 12`，强调层完全落在面板圆角之内
    ///   （取 `sm`(12) 会在对角方向露出约 2.5pt 方角，见 `DesignTokens.Radius.xs`）。
    static let buttonStyle = PressableCardButtonStyle(
        pressedScale: 0.97,
        shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xs))
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
///
/// ⚠️ 不是 `private`：跳章条已拆到 `ReaderView+ChromeJumpBar.swift`，而 `private` 是
/// **文件级**的 —— 那边的「上一章 / 下一章」label 仍走这一处构建（字体 / 命中区 / 无障碍
/// 的施加方式必须保持只有一处）。
func chromeIconLabel(
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

/// 圆角面板的玻璃背景：系统材质 + 主题染色（带羽化）+ 0.5pt 细边缘线 + 只朝正文方向的柔影。
///
/// 形状与「上一版」的圆角面板同源（`RoundedRectangle(cornerRadius: Radius.lg)`）；
/// 玻璃语言（材质 / 染色 / 边缘 / 投影）来自 `ReaderChromeStyle` 的派生 ——
/// 三条面板共用这一个视图 ⇒ 材质 / 染色 / 边缘 / 投影 / 圆角在结构上无法分叉。
///
/// ⚠️ 不是 `private`：跳章条已拆到 `ReaderView+ChromeJumpBar.swift`，而 `private` 是
/// **文件级**的 —— 那边的面板背景仍必须走这一处（玻璃语言不能出现第二份实现）。
struct ReaderChromeGlass: View {
    let style: ReaderChromeStyle
    let edge: ReaderChromeEdge

    /// 面板形状：`Radius.lg`(18)，与「上一版」的圆角面板逐值相同。
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
    }

    var body: some View {
        ZStack {
            shape.fill(style.material)
            shape.fill(style.tint)
                .mask(featherMask)
        }
        .overlay(alignment: edge.contentAnchor) {
            Rectangle()
                .fill(style.edgeColor)
                .frame(height: ReaderChromeMetrics.edgeLineHeight)
        }
        // 边缘线是一条**直**线，会在面板圆角外露出两个方角 ⇒ 先按面板形状裁一次。
        // 必须在 `compositingGroup` 之前：裁切属于「这一层长什么样」，
        // 裁完再合成、再投影，投影才会沿着圆角走。
        .clipShape(shape)
        // 先合成成一层再投影：否则投影会分别落在材质 / 染色 / 边缘线上，接缝处出现重影。
        .compositingGroup()
        .shadow(color: style.shadowColor, radius: style.shadowRadius, x: 0, y: edge.shadowOffsetY)
    }

    /// 内侧羽化遮罩：从面板内满染淡到贴近正文处 0.78。
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
/// 结构取「上一版」：`HStack { 返回 · Spacer · 章节名 · Spacer · 更多 }`
/// + `Spacing.md` 横向 / `Spacing.sm` 竖向内边距 + 圆角面板背景 + `Spacing.md` 外留边。
/// 两侧按钮的命中区同为 44pt、两个 `Spacer` 等宽 ⇒ 标题**天然居中**，不需要手工预留宽度。
///
/// 「更多」是项目既有的入口（U9-6 把原来的 `eye.slash` 换成了 `ellipsis.circle`）。
/// 菜单里现在是**真入口**「书籍详情」（owner 需求：详情页入口收进阅读页右上角「更多」）。
/// `onShowDetail` 为 `nil` 时（测试 / 预览那条没有 `bookPath` 的构造路径）保留原来的置灰占位项
/// —— 空 `Menu` 点开是一片空白，用户会以为控件坏了（§11 反馈：别给一个点了没反应的入口）。
private struct ReaderTopBar: View {
    let title: String
    let style: ReaderChromeStyle
    /// 「书籍详情」的落点；`nil` = 不提供这一项（见类型文档）。
    var onShowDetail: (() -> Void)?
    var onBack: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            iconButton(
                "返回",
                systemImage: "chevron.left",
                opticalScale: ReaderChromeMetrics.chevronOpticalScale,
                action: onBack
            )

            Spacer(minLength: 0)

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            moreMenu
        }
        .buttonStyle(ReaderChromeMetrics.buttonStyle)
        .foregroundStyle(style.foreground)
        .padding(.horizontal, ReaderChromeMetrics.topBarInnerPadding)
        .padding(.vertical, ReaderChromeMetrics.panelVerticalPadding)
        .background {
            ReaderChromeGlass(style: style, edge: .top)
        }
        .padding(.horizontal, ReaderChromeMetrics.panelOuterMargin)
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
    /// 菜单项：「书籍详情」—— 真入口，点开是**覆盖在阅读页之上**的 sheet（不是 push，
    /// 理由见 `ReaderView.detailSheet`）；`onShowDetail` 为 `nil` 时保留原来的置灰占位项。
    private var moreMenu: some View {
        Menu {
            if let onShowDetail {
                Button(action: onShowDetail) {
                    Label("书籍详情", systemImage: "info.circle")
                }
            } else {
                Button("更多选项待添加") {}
                    .disabled(true)
            }
        } label: {
            chromeIconLabel("ellipsis.circle", a11yLabel: "更多")
        }
        // 显式再挂一次按下反馈。外层 `HStack` 已经把**同一个** `buttonStyle` 注入环境，
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

// 章节跳转条（`ReaderChapterJumpBar`）已搬到 `ReaderView+ChromeJumpBar.swift`：
// 本文件已 580 行、距 `file_length` 600 只剩 20 行，装不下新增的页码进度条。

// MARK: - 下栏

/// 下栏：目录 · 下载 · 搜索 · 设置（图标 + 11pt 文字标签，等分栏宽）。
///
/// 条目以**项目既有能力**为准（owner：「依照原样，项目代码只是参考，下栏依次为目录，下载搜索设置」）：
/// 目录 / 搜索 / 设置各打开既有 sheet；下载打开**章节选择面板**（实现在 `ReaderView+DownloadPicker.swift`）。
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
        .padding(.horizontal, ReaderChromeMetrics.barInnerPadding)
        .padding(.vertical, ReaderChromeMetrics.panelVerticalPadding)
        .background {
            ReaderChromeGlass(style: style, edge: .bottom)
        }
        .padding(.horizontal, ReaderChromeMetrics.panelOuterMargin)
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

/// 控制栏叠加层：三条圆角面板（上栏贴顶、跳章条 + 下栏贴底），
/// **浮在正文之上、不参与正文布局**。
///
/// ## 为什么必须是叠加层
/// 呼出 / 隐藏控制栏**不能**改变正文的分页与阅读位置。它作为 `ZStack` 里与正文并列的一层
/// （见 `ReaderView.body`），自己不占正文的布局空间 ⇒ 正文层一行都不动
/// （`readerContentPaddings` / `readerContentSize` 这两个函数名与它们的几何契约未变；
/// 但**函数体**已随「上下边距换语义」改过 —— 外层直接用设定值、不再牵涉安全区，
/// `readerContentPaddings` 现在只吃 `inset`）。
///
/// ## 竖向位置：不吃安全区（U9-7）
/// 这一层**只吃横向安全区**（由 `ReaderView.body` 施加），竖向完全由三段 `padding` 决定：
/// - 上栏 `.padding(.top, topPadding)` —— `topPadding` 是
///   `ReaderView.topBarPadding(safeAreaInsets:)` 算好的「上栏上边缘距屏幕顶」，
///   比安全区**更贴屏幕顶**（标题字形仍落在灵动岛下沿以下）；
/// - 跳章条与下栏各 `.padding(.bottom, Spacing.xs)` —— 下栏下边缘距屏幕底 8pt，
///   栏自身 12pt 内边距正好把 Home Indicator 那根细条让在空处。
struct ReaderChromeOverlay: View {
    let style: ReaderChromeStyle
    let chapterTitle: String
    /// 上栏的上边缘距屏幕顶的距离（由 `ReaderView.topBarPadding(safeAreaInsets:)` 算好传入）。
    let topPadding: CGFloat
    /// 相邻章节（`ReaderFeature.State` 的派生属性）：`nil` = 到边界，跳章条据此置灰。
    let previousChapter: ChapterItem?
    let nextChapter: ChapterItem?

    var onBack: () -> Void
    var onContents: () -> Void
    var onDownload: () -> Void
    var onSearch: () -> Void
    var onSettings: () -> Void
    /// 「更多 → 书籍详情」；`nil` = 菜单里不出现这一项（原样透传给 `ReaderTopBar`）。
    var onShowDetail: (() -> Void)?
    /// 跳章：上一章 / 下一章**共用**一个闭包（两侧都走既有的 `loadChapterWithName` 正常加载路径）。
    var onJumpToChapter: (ChapterItem) -> Void
    /// 本章页码 + 跳页回调（原样透传给跳章条中间的进度条，见 `ReaderPageJump`）。
    ///
    /// 收成一个值类型而不是 4 个参数：`ReaderChapterJumpBar` 的参数个数会越过
    /// `function_parameter_count` 的 warning 5（理由见 `ReaderPageJump` 的类型注释）。
    var pageJump: ReaderPageJump

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ReaderTopBar(
                title: chapterTitle,
                style: style,
                onShowDetail: onShowDetail,
                onBack: onBack
            )
            .padding(.top, topPadding)
            .transition(.chromeBar(edge: .top, reduceMotion: reduceMotion))

            Spacer(minLength: 0)

            // 章节跳转条：贴在下栏上方 8pt（`DesignTokens.Spacing.xs`）。
            // 转场与下栏同向（自下 8pt 滑入）：它与下栏是一起从屏幕底部进来的。
            ReaderChapterJumpBar(
                style: style,
                previousChapter: previousChapter,
                nextChapter: nextChapter,
                onJumpToChapter: onJumpToChapter,
                pageJump: pageJump
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
            .padding(.bottom, DesignTokens.Spacing.xs)
            .transition(.chromeBar(edge: .bottom, reduceMotion: reduceMotion))
        }
        // 三条面板各自带方向相反的转场；容器自己不再叠一层淡入，否则淡入会叠成两层。
        .transition(.identity)
    }
}

// MARK: - 转场

private extension AnyTransition {
    /// 控制栏呼出 / 隐藏的转场：淡入 + 轻微位移（上栏自上 8pt、下栏与跳章条自下 8pt）。
    ///
    /// Reduce Motion 时**只做淡入**：位移是前庭刺激，降级 ≠ 无反馈 —— 淡入仍在，
    /// 按下强调层（`PressableCardButtonStyle`）也不受 Reduce Motion 影响。
    static func chromeBar(edge: ReaderChromeEdge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(x: 0, y: edge.enterOffsetY))
    }
}

// MARK: - 与 ReaderView 的接线

extension ReaderView {
    /// 阅读页**正文底色**的唯一来源（正文层铺底与角落 HUD 用它）。
    ///
    /// ⚠️ 三条控制栏面板**不再**消费它：面板已改成系统语义色（`ReaderView+ChromeStyle.swift`），
    /// 不再跟随正文染色。本函数保留是因为 `ReaderView.swift` 仍在用它
    /// （正文铺底 `Color(uiColor:)` 与 `readerCornerHUD(pageColor:)`）。
    ///
    /// 返回 `UIColor` 而不是 `Color`：调用点要拿它铺底并派生 HUD 文字色，
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
