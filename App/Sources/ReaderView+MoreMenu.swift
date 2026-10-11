import SwiftUI

// 阅读页右上角「更多」的**自绘下拉面板**（owner 2026-10-11 真机反馈：
// 「阅读界面右上角更多选项弹出的选项和上栏重叠且背景颜色不同」）。
//
// ## 为什么不再用系统 `Menu`
// 改造前 `ReaderTopBar.moreMenu` 是系统 `Menu`，那两条问题**都不由我们控制**：
// 1. **位置**：系统弹层锚在「更多」按钮上，而按钮在上栏面板内部（面板 68pt 高）
//    ⇒ 弹层必然压住上栏面板的下半部分，且没有任何公开 API 能指定它的位置；
// 2. **材质**：系统菜单用 iOS 自己的菜单材质 + vibrancy，与上下栏的
//    「`.regularMaterial` + `secondarySystemBackground`@0.92」**不是同一层材质**
//    ⇒ 无论怎么调都不可能逐像素同色。
//
// ⇒ 自绘：面板复用**同一套** `ReaderChromeGlass` + `ReaderChromeStyle`（颜色逐像素一致），
// 位置由布局决定（在上栏下方 `Spacing.xs`(8pt)、右对齐）⇒ 结构上**不可能**与上栏重叠。
//
// ## 内容做成「数组 → 逐项渲染」
// 现在只有一项（「书籍详情」），但渲染路径是 `[ReaderMoreMenuItem]` 的遍历 ⇒
// **以后加项只改数组**（`ReaderMoreMenuItem.readerMoreMenu(onShowDetail:)`），不动视图。

// MARK: - 条目模型

/// 下拉面板的一项。
///
/// ## 为什么 `action` 收在项里、却**不由面板执行**
/// 面板只把「选中了哪一项」上报给 `onSelect`，由 `ReaderChromeOverlay` 那**唯一一处**
/// 统一做「**先收面板、再执行动作**」—— 点「书籍详情」会打开 sheet，面板必须先消失，
/// 否则 sheet 关掉后面板还杵在那儿。⇒ 执行路径只有一条，加项时不必各自重复这段逻辑。
struct ReaderMoreMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// `false` ⇒ 渲染成置灰项且**不可点**：`.disabled(true)` 会让 `ButtonStyle` 收不到按下事件
    /// ⇒ 连按下反馈都没有（与跳章条到边界时的处置同源）。
    let isEnabled: Bool
    let action: () -> Void
}

extension ReaderMoreMenuItem {
    /// 本页当前的菜单项（**唯一的数组构造处** ⇒ 以后加项只改这里）。
    ///
    /// - `onShowDetail != nil` ⇒ 一项「书籍详情」，点开是**覆盖在阅读页之上**的 sheet
    ///   （不是 push，理由见 `ReaderView.detailSheet`）。
    /// - `onShowDetail == nil` ⇒ 一项**置灰**的「更多选项待添加」：那条路径是测试 / 预览
    ///   （没有 `bookPath`），保留占位项与改造前**逐字相同** —— 空面板会让人以为控件坏了
    ///   （§11：别给一个点了没反应的入口，也别给一个空壳）。
    ///   图标取「更多」自己的 `ellipsis.circle`：占位项没有专属图标，用打开它的那个入口的图标
    ///   最不突兀，也让图标列不至于空一格（多行时文字左边缘才能对齐）。
    static func readerMoreMenu(onShowDetail: (() -> Void)?) -> [ReaderMoreMenuItem] {
        if let onShowDetail {
            return [
                ReaderMoreMenuItem(
                    id: "detail",
                    title: "书籍详情",
                    systemImage: "info.circle",
                    isEnabled: true,
                    action: onShowDetail
                ),
            ]
        }
        return [
            ReaderMoreMenuItem(
                id: "placeholder",
                title: "更多选项待添加",
                systemImage: "ellipsis.circle",
                isEnabled: false,
                action: {}
            ),
        ]
    }
}

// MARK: - 尺度

/// 下拉面板专有的尺度（**有名字、带推导**，不散落成魔数）。
private enum ReaderMoreMenuMetrics {
    /// 20 —— 图标列宽。`.body`(17pt) 下 SF Symbol 的方形图标位（17 × 1.2 ≈ 20）。
    ///
    /// 固定成**列宽**是为了多项时文字左边缘能对齐：SF Symbols 的墨迹宽窄不一
    /// （`info.circle` 铺满字身、`bookmark` 很窄），不固定列宽每项文字起点都会参差。
    static let iconColumnWidth: CGFloat = 20

    /// 184 —— 标题文字的最大宽度（= `maxPanelWidth` − 24 − 20 − 12）。
    ///
    /// 它是**面板宽度的实际决定项**：面板宽 = min(内容宽, 240)，而内容宽 = 24 + 20 + 12 + 文字宽，
    /// 所以「最长 184 的文字」正好把面板顶到 240 —— 两项互相印证，改一个必须改另一个。
    /// 文字短时面板就窄（贴合内容），文字长时先缩到这里、再 `lineLimit(1)` 截断。
    static let maxTitleWidth: CGFloat = 184

    /// 240 —— 面板的最大宽度。算式：
    /// 横向内边距 `ReaderChromeMetrics.barInnerPadding`(12) × 2 = **24**
    /// + 图标列 **20** + 图标与文字的间距 `Spacing.sm`(12) + 标题上限 **184** = **240**。
    ///
    /// ⚠️ 为什么 240 结构上**不可能溢出屏幕**：面板左右各留
    /// `ReaderChromeMetrics.panelOuterMargin`(16) ⇒ 需要 240 + 32 = **272pt**，
    /// 而可运行 iOS 17 的最窄机型是 **320pt** ⇒ 余量 **48pt**
    /// （Dynamic Type 下超长词条由 `maxTitleWidth` 截断，而不是把面板顶出屏幕）。
    static let maxPanelWidth: CGFloat = 240
}

// MARK: - 点面板外关闭

/// 点面板外任意处关闭面板用的**全屏透明捕获层**。
///
/// ## 层级（由调用点 `ReaderChromeOverlay` 决定，这里只声明「是什么」）
/// 它挂在控制栏 `VStack` 的 `.background` 上 ⇒ 位于控制栏本体**之下**，但整层又在
/// **正文层之上**（控制栏叠加层整体压在正文层上）⇒ 点空白处**只收面板**，
/// 不会顺手触发正文那条「中央点击呼出 / 隐藏控制栏」。
///
/// ## 面板打开时它是**完全模态**的（owner 口径）
/// 控制栏那三条栏在面板打开时会**让出命中**（各挂一行
/// `.allowsHitTesting(!isShowingMoreMenu)`，见 `ReaderChromeOverlay.body` 顶部那段因果）
/// ⇒ 点上下栏的按钮**也**落到这一层：只收面板、不触发那个按钮。
/// 面板本身不在让出之列（它声明在栏之后、画在栏之上）⇒ 面板内的项照常可点。
///
/// ⚠️ 不要改成 `.overlay`：那样它会盖住上下栏，连「让出命中」这条都不需要，
/// 但也就不再有「面板在栏之上」的天然层级 —— 两处一起改容易改漏。
struct ReaderMoreMenuDismissLayer: View {
    let onDismiss: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
            // 装饰性：它不是可读元素。VoiceOver 用户再点一次「更多」即可收起
            // （同一个开关，展开时带 `.isSelected`）。
            .accessibilityHidden(true)
    }
}

// MARK: - 面板

/// 右上角「更多」的**下拉面板**：与上下栏同一套玻璃，右对齐、贴在上栏下方 8pt。
///
/// ## 为什么 `edge: .top`
/// `ReaderChromeEdge` 的语义是「**贴近正文的那一侧**」：本面板的内容在**下方**（正文方向）
/// ⇒ 边缘线画在**下沿**、柔影朝下（`shadowOffsetY = +5`）落在正文上，
/// **不会**把上方的上栏压暗 —— 那正是改造前「颜色不一致」的另一半原因。
/// 圆角与材质由 `ReaderChromeGlass` 自带（`Radius.lg`(18) + `.regularMaterial` + 系统底色 @0.92），
/// 本文件**不**再画第二层卡面。
///
/// ## 显隐状态不在这里
/// 面板自己不持有显隐状态：状态住在控制栏叠加层（`ReaderChromeOverlay`），
/// 控制栏一隐藏整层被移除 ⇒ 状态自动归零，面板不可能残留在屏幕上。
/// 这也是本次改造**完全不碰** `ReaderView.swift` 的原因。
struct ReaderMoreMenuPanel: View {
    let style: ReaderChromeStyle
    let items: [ReaderMoreMenuItem]
    /// 选中回调（**唯一**执行路径；面板自己不执行 `item.action`，理由见 `ReaderMoreMenuItem`）。
    let onSelect: (ReaderMoreMenuItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // 行间分隔线用系统 `Divider()`（不自算 1px），与分组栏那条同源。
                // 单项时不渲染 ⇒ 面板不会多出一条悬空的分隔线。
                if index > 0 {
                    Divider()
                }
                row(item)
            }
        }
        .padding(.vertical, ReaderChromeMetrics.panelVerticalPadding)
        // ## 宽度 = min(内容宽, 240)：先封顶、再**强制贴合内容**
        // `.frame(maxWidth:)` 单独用**不足以保证贴合**（它是「夹取提案」的语义，遇到弹性提案
        // 会跟着提案走）⇒ 在它**之后**加 `.fixedSize(horizontal: true, vertical: false)`：
        // 这一层向下提案「未指定宽度」，内层 frame 于是按内容的**理想宽**定尺寸，
        // 面板宽因此 = 内容宽（短词条得到一个小面板，像系统菜单）。
        // 封顶仍由内层 frame 的 240 保证；超长词条由每一行自己的 `maxTitleWidth`(184) 截断
        // ⇒ 内容宽**结构上不可能**超过 240。
        // ⚠️ 顺序不可换：`.fixedSize` 必须在 `.background { ReaderChromeGlass }` **之前**，
        // 否则玻璃会按外层提案拉伸，面板右侧留出一条没有内容的空玻璃。
        .frame(maxWidth: ReaderMoreMenuMetrics.maxPanelWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(style.foreground)
        .background {
            ReaderChromeGlass(style: style, edge: .top)
        }
    }

    /// 一行：图标 + 文字。
    ///
    /// ## 命中区与按下反馈
    /// 行高 ≥ `ReaderChromeMetrics.minTouchTarget`(44)（HIG §9），整块 `contentShape` 可点；
    /// 按下反馈**复用控制栏那一个** `buttonStyle`（`PressableCardButtonStyle`）——
    /// 面板与上下栏的按钮因此是同一种反馈，不另造第二个按下样式。
    ///
    /// ## 为什么横向内边距取 12 而不是上栏的 16
    /// 那个 12 是 `buttonStyle` 强调层圆角 `Radius.xs`(6) 的**几何前提**
    /// （`6 = Radius.lg`(18) `−` 12，见 `DesignTokens.Radius.xs`）⇒
    /// 强调层完全落在面板圆角之内，按下时四角不会露出方角。
    /// 竖向内边距同样是 12（`panelVerticalPadding`），首尾两行上下也内缩 12pt。
    private func row(_ item: ReaderMoreMenuItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: item.systemImage)
                    .font(ReaderChromeMetrics.iconFont)
                    .frame(width: ReaderMoreMenuMetrics.iconColumnWidth)

                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                    .frame(maxWidth: ReaderMoreMenuMetrics.maxTitleWidth, alignment: .leading)
            }
            .frame(minHeight: ReaderChromeMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReaderChromeMetrics.buttonStyle)
        .disabled(!item.isEnabled)
        // 置灰只靠 `.disabled` 不够：本项目按钮走**自定义** `ButtonStyle`，系统不会替它降级外观
        // ⇒ 不显式调透明度就会「看着能点、点下去没反应」（与跳章条的处置同源，同一个常量）。
        .opacity(item.isEnabled ? 1 : ReaderChromeMetrics.disabledOpacity)
    }
}

// MARK: - 与 ReaderChromeOverlay 的接线

// 「更多」的**面板 + 接线**都住在本文件（面板的线跟面板走）：`ReaderView+Chrome.swift`
// 加完接线后一度只剩 7 行余量，而 `file_length` 600 是 CI 硬门（`--strict` ⇒ warning 即失败）；
// 这几块只服务「更多」面板、与上栏 / 下栏 / 跳章条零耦合 ⇒ 整体搬出来。
// 代价与既有先例相同：`ReaderChromeOverlay.isShowingMoreMenu` 不能再是 `private`
// （Swift 的 `private` 是本文件级的；先例见 `BookshelfView` 那三个分组弹窗 `@State`）。

extension ReaderChromeOverlay {
    /// 「更多」下拉面板本体：**夹在上栏与 `Spacer` 之间** ⇒ 由布局保证「永远贴在上栏下方
    /// 8pt、绝不与上栏重叠」（改造前系统 `Menu` 的弹层会压住上栏下半截）。
    /// 右对齐 + 外留边与上栏同源（`panelOuterMargin`）⇒ 面板右边缘与上栏右边缘对齐。
    ///
    /// ⚠️ `reduceMotion` 由调用方传入、不在这里读 `@Environment`：那个 `@Environment`
    /// 是 `ReaderView+Chrome.swift` 里的 file-private 成员，本文件读不到 ——
    /// 为它再放开一个可见性不如显式传参（本函数只多一个形参）。
    @ViewBuilder
    func moreMenuLayer(
        isShowing: Bool,
        reduceMotion: Bool,
        onSelect: @escaping (ReaderMoreMenuItem) -> Void
    ) -> some View {
        if isShowing {
            ReaderMoreMenuPanel(
                style: style,
                items: ReaderMoreMenuItem.readerMoreMenu(onShowDetail: onShowDetail),
                onSelect: onSelect
            )
            .padding(.top, DesignTokens.Spacing.xs)
            .padding(.horizontal, ReaderChromeMetrics.panelOuterMargin)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.chromeBar(edge: .top, reduceMotion: reduceMotion))
        }
    }

    /// 点面板外关闭的**全屏透明捕获层**：由调用点挂在控制栏 `VStack` 的 `.background` 上
    /// ⇒ 位于控制栏本体**之下**，而整层又在**正文层之上**（控制栏叠加层整体压在正文层上）
    /// ⇒ 点空白处**只收面板**，不会顺手触发正文那条「中央点击呼出 / 隐藏控制栏」。
    /// 面板打开时三条栏**让出命中** ⇒ 点上下栏的按钮也只收面板（完全模态，owner 口径）。
    /// ⚠️ 不要改成 `.overlay`：层级与「栏让出命中」两处要一起改，容易改漏。
    @ViewBuilder
    var moreMenuDismissLayer: some View {
        if isShowingMoreMenu {
            ReaderMoreMenuDismissLayer { setMoreMenu(false) }
        }
    }

    /// 面板显隐的**唯一写入口**：开关按钮 / 点面板外 / 选中某项三条路径都走它。
    ///
    /// 曲线与上下栏同一条（`.easeOut` + `toggleDuration`），但**这里不返回 `nil`**：
    /// Reduce Motion 的降级放在**转场**里（`chromeBar` 退化为纯淡入），曲线若也返回 nil，
    /// 面板就会「啪」地出现、连淡入都没有 —— 降级 ≠ 无反馈。
    func setMoreMenu(_ isShowing: Bool) {
        withAnimation(.easeOut(duration: ReaderChromeMetrics.toggleDuration)) {
            isShowingMoreMenu = isShowing
        }
    }

    /// 选中一项：**先收面板、再执行动作**（唯一执行路径，理由见 `ReaderMoreMenuItem`）。
    func selectMoreMenuItem(_ item: ReaderMoreMenuItem) {
        setMoreMenu(false)
        item.action()
    }
}
