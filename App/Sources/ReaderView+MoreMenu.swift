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
// 现在是三项（**目录 / 书籍详情 / 加入书架**），但渲染路径仍是 `[ReaderMoreMenuItem]` 的遍历 ⇒
// **以后加项只改数组**（`ReaderMoreMenuItem.readerMoreMenu(…)`），不动视图。
//
// ## 几何（2026-10-11 owner 定稿：**一个选项 = 一张卡片**）
// 每张卡片按**自己的文字宽**定尺寸：宽 = 文字 + `textHorizontalPadding`(12) × 2 + `cardPadding`(4) × 2、
// 高 = 行高 44 + 4 × 2 = **52** ⇒ 单项「书籍详情」= **100 × 52**；
// 四边视觉留白**相等**（上下 `(44 − 20) / 2 + 4 = 16` = 左右 `12 + 4 = 16`）。
// 卡片之间留 `Spacing.xs`(8)、整体右对齐（`VStack(alignment: .trailing)`）。
// **按下高亮覆盖整张卡片**：内边距与玻璃都在 Button 的 label 内部 ⇒ label 的 frame 就是卡片，
// 强调层的 `shape` 取同一个 `Radius.lg`(18) ⇒ 与卡片完全重合（零内缩、天然同心）。
// 推导见 `ReaderMoreMenuMetrics` 与 `card(_:)`。

// MARK: - 条目模型

/// 下拉面板的一项。
///
/// ## 为什么 `action` 收在项里、却**不由面板执行**
/// 面板只把「选中了哪一项」上报给 `onSelect`，由 `ReaderChromeOverlay` 那**唯一一处**
/// 统一做「**先收面板、再执行动作**」—— 点「书籍详情」会打开 sheet，面板必须先消失，
/// 否则 sheet 关掉后面板还杵在那儿。⇒ 执行路径只有一条，加项时不必各自重复这段逻辑。
struct ReaderMoreMenuItem: Identifiable {
    let id: String
    /// 菜单项文字（**纯文字项**）。
    let title: String
    /// `false` ⇒ 渲染成置灰项且**不可点**：`.disabled(true)` 会让 `ButtonStyle` 收不到按下事件
    /// ⇒ 连按下反馈都没有（与跳章条到边界时的处置同源）。
    let isEnabled: Bool
    let action: () -> Void
}

extension ReaderMoreMenuItem {
    /// 本页当前的菜单项（**唯一的数组构造处** ⇒ 以后加项只改这里）。
    ///
    /// 顺序固定为 **目录 / 书籍详情 / 加入书架**。
    /// - 「目录」= 阅读页下栏那个目录入口的**同一个** action（`onShowContents` ⇒
    ///   `ReaderView.isShowingDirectory`）⇒ 打开的是**同一个** sheet，不新建第二个。
    /// - 「加入书架」是**纯文字项**（owner：「加入书架不要符号只要文字」）⇒ 不加图标；
    ///   `isOnShelf == true` ⇒ 文字变「已在书架」且置灰不可点（`isEnabled: false`，
    ///   置灰与不可点的既有处置见 `ReaderMoreMenuPanel.card(_:)`）。
    /// - `onShowDetail == nil` ⇒ 一项**置灰**的「更多选项待添加」：那条路径是测试 / 预览
    ///   （没有 `bookPath`），保留占位项与改造前**逐字相同** —— 空面板会让人以为控件坏了
    ///   （§11：别给一个点了没反应的入口，也别给一个空壳）。
    static func readerMoreMenu(
        isOnShelf: Bool,
        onShowContents: @escaping () -> Void,
        onShowDetail: (() -> Void)?,
        onAddToShelf: @escaping () -> Void
    ) -> [ReaderMoreMenuItem] {
        if let onShowDetail {
            return [
                ReaderMoreMenuItem(
                    id: "contents",
                    title: "目录",
                    isEnabled: true,
                    action: onShowContents
                ),
                ReaderMoreMenuItem(
                    id: "detail",
                    title: "书籍详情",
                    isEnabled: true,
                    action: onShowDetail
                ),
                ReaderMoreMenuItem(
                    id: "shelf",
                    title: isOnShelf ? "已在书架" : "加入书架",
                    isEnabled: !isOnShelf,
                    action: onAddToShelf
                ),
            ]
        }
        return [
            ReaderMoreMenuItem(
                id: "placeholder",
                title: "更多选项待添加",
                isEnabled: false,
                action: {}
            ),
        ]
    }
}

// MARK: - 尺度

/// 下拉面板专有的尺度（**有名字、带推导**，不散落成魔数）。
///
/// ⚠️ 卡片的两个内边距在这里**自己开常量**，**不**复用
/// `ReaderChromeMetrics.panelVerticalPadding`(12) / `barInnerPadding`(12)：
/// 那两条是**上下栏与跳章条**的内边距（三者同高 68pt 靠的就是它），
/// 菜单卡片要的是更紧凑的一档（4 + 12）—— 复用共享常量会把三条面板一起压扁或撑高。
private enum ReaderMoreMenuMetrics {
    /// 4 —— **卡片的内边距**（上下左右同一个值）。
    ///
    /// ## ⚠️ 它加在 **Button 的 label 内部**（不是卡片外面）
    /// 这样 label 的 frame **就是整张卡片**，按下强调层（`PressableCardButtonStyle` 的 overlay）
    /// 因此与卡片**完全重合**（同一形状、同一圆角 `Radius.lg`(18)、**零内缩**）——
    /// owner 口径「点击效果的圆角要覆盖到整个卡片」。同心是**构造上的恒等式**（同一个圆角值）。
    /// ⛔ 不要再把它挪到卡片外面：那样强调层会被内缩 4pt，既与卡片不同心、又要在圆角处算余量。
    static let cardPadding: CGFloat = 4

    /// 12 —— 文字**额外**的左右内边距（加在 `Text` 那一层）。
    ///
    /// ## owner 口径：文字四周的视觉留白必须**相等**
    /// - **上下** = 行高 44 与文字行高 ≈20 的差的一半 `(44 − 20) / 2 = 12` + 卡片内边距 4 = **16pt**；
    /// - **左右** = 本常量 12 + 卡片内边距 4 = **16pt** ⇒ 与上下相等 ✓。
    /// ⇒ 这就是 owner 说的「左右边距」——指的是**文字距卡片边框**的距离，
    /// 不是可点区域那一层（可点区域仍是整张卡片）。
    static let textHorizontalPadding: CGFloat = 12

    /// 240 —— **每张卡片**的最大宽度（语义已从「整个面板的上限」变成「单张卡片的上限」）。
    ///
    /// 卡片宽 = 文字 + `textHorizontalPadding`(12) × 2 + `cardPadding`(4) × 2
    /// ⇒ **文字上限 = 240 − 32 = 208**，超长词条在这一段内由 `lineLimit(1)` 截断。
    ///
    /// ⚠️ 为什么 240 结构上**不可能溢出屏幕**：卡片左右各留
    /// `ReaderChromeMetrics.panelOuterMargin`(16) ⇒ 需要 240 + 32 = **272pt**，
    /// 而可运行 iOS 17 的最窄机型是 **320pt** ⇒ 余量 **48pt**。
    ///
    /// ⛔ **刻意没有「最小宽度」**：有了它，短词条的卡片会被托宽、而文字仍居中
    /// ⇒ 左右留白远大于上下（16pt）—— 那正是 owner 这次指出的「不一致」。
    /// 卡片按**自己的文字宽**定尺寸，四边留白才天然相等。
    static let maxCardWidth: CGFloat = 240
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

/// 右上角「更多」的**下拉区**：与上下栏同一套玻璃，右对齐、贴在上栏下方 8pt。
///
/// ## ⚠️ 结构是「**一个选项 = 一张卡片**」（owner 2026-10-11 口径）
/// 本视图只是把若干张**各自独立**的卡片按 `.trailing` 堆起来：
/// 每张卡片自带 `ReaderChromeGlass`（圆角 / 材质 / 边缘线 / 柔影）、按**自己的文字宽**定尺寸，
/// 卡片之间留 `Spacing.xs`(8)。**没有** `Divider()`（卡片之间不需要分隔线），
/// 也**没有**「整块面板的内边距 / 最小宽度」——那两条会破坏「文字四边留白相等」。
/// ⇒ 以后新增一个选项就是**再加一张卡片**，不要再改回「一个面板装多行」。
///
/// ## 为什么 `edge: .top`
/// `ReaderChromeEdge` 的语义是「**贴近正文的那一侧**」：卡片的内容在**下方**（正文方向）
/// ⇒ 边缘线画在**下沿**、柔影朝下（`shadowOffsetY = +5`）落在正文上，
/// **不会**把上方的上栏（或上一张卡片）压暗 —— 那正是改造前「颜色不一致」的另一半原因。
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
        // ## 一个选项 = 一张卡片（owner 口径）
        // 以后新增一个选项就是**再加一张卡片**，不要再改回「一个面板装多行 + 分隔线」。
        // 每张卡片**各自**带 `ReaderChromeGlass`（圆角 / 材质 / 边缘线 / 柔影都在它里面）⇒ 不需要 `Divider()`；
        // 卡片之间留 `Spacing.xs`(8) —— 与「面板距上栏 8pt」**同一个令牌**。
        // ⚠️ `alignment: .trailing` 是必须的：外层已经右对齐 ⇒ 每张卡片按**自己的宽度**、
        // 且**右边缘对齐**；左边缘允许参差（owner 已确认）。
        VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
            ForEach(items) { item in
                card(item)
            }
        }
        .foregroundStyle(style.foreground)
    }

    /// 一张卡片：**纯文字**、四边视觉留白相等、按**自己的文字宽**定尺寸、**按下高亮覆盖整张卡片**。
    ///
    /// ## 命中区与按下反馈
    /// 行高 ≥ `ReaderChromeMetrics.minTouchTarget`(44)（HIG §9），整块 `contentShape` 可点。
    /// 按下反馈用 `PressableCardButtonStyle`，**`shape` 传 `Radius.lg`(18)** ——
    /// 与 `ReaderChromeGlass` 自己的圆角**同一个值** ⇒ 强调层与卡片**完全重合**
    /// （同一形状、同一圆角、**零内缩**），同心是构造上的恒等式。
    /// ⛔ 不要再传 `Radius.xs`(6)、也**不要**把 `cardPadding` / 玻璃挪到 Button 外面：
    /// 那样强调层会被内缩、与卡片不同心，还要在圆角处算「会不会露方角」的余量。
    ///
    /// ## 四边视觉留白相等（owner 口径）
    /// - **上下** = 行高 44 与文字行高 ≈20 之差的一半 `(44 − 20) / 2 = 12` + `cardPadding`(4) = **16pt**；
    /// - **左右** = `textHorizontalPadding`(12) + `cardPadding`(4) = **16pt** ✓。
    /// owner 说的「左右边距」指的是**文字距卡片边框**的距离 —— 可点区域仍是整张卡片。
    ///
    /// ## 宽度：按自己的文字宽（⛔ 没有最小宽度）
    /// `textHorizontalPadding` 加在 `Text` 那一层、`cardPadding` 加在它外面（**都在 label 内**）
    /// ⇒ 卡片宽 = 文字 + 12×2 + 4×2；`.fixedSize(horizontal: true, vertical: false)` 让卡片按
    /// **理想宽**定尺寸（玻璃在 label 内、贴着 label，因此不会出现「空玻璃」）。
    /// 超长词条由 `maxCardWidth`(240) 封顶、文字在 240 − 32 = **208pt** 内 `lineLimit(1)` 截断。
    /// ⛔ 刻意**不**引入「最小宽度」：那会把短词条的卡片托宽、而文字仍居中
    /// ⇒ 左右留白远大于上下，正是 owner 指出过的不一致。
    private func card(_ item: ReaderMoreMenuItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            Text(item.title)
                .font(.body)
                .lineLimit(1)
                .padding(.horizontal, ReaderMoreMenuMetrics.textHorizontalPadding)
                .frame(minHeight: ReaderChromeMetrics.minTouchTarget)
                // 卡片内边距与玻璃都在 **label 内部** ⇒ label 的 frame 就是整张卡片，
                // 强调层（画在 label 上）因此覆盖整张卡片。
                .padding(ReaderMoreMenuMetrics.cardPadding)
                .contentShape(Rectangle())
                .background {
                    ReaderChromeGlass(style: style, edge: .top)
                }
        }
        .buttonStyle(
            PressableCardButtonStyle(
                shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            )
        )
        .disabled(!item.isEnabled)
        // 置灰只靠 `.disabled` 不够：本项目按钮走**自定义** `ButtonStyle`，系统不会替它降级外观
        // ⇒ 不显式调透明度就会「看着能点、点下去没反应」（与跳章条的处置同源，同一个常量）。
        // ⚠️ `.disabled` 同时让 `ButtonStyle` 收不到按下事件 ⇒ 置灰项**没有**按下反馈（刻意保持）。
        .opacity(item.isEnabled ? 1 : ReaderChromeMetrics.disabledOpacity)
        .frame(maxWidth: ReaderMoreMenuMetrics.maxCardWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
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
                items: ReaderMoreMenuItem.readerMoreMenu(
                    isOnShelf: isOnShelf,
                    onShowContents: onContents,
                    onShowDetail: onShowDetail,
                    onAddToShelf: addBookToShelf
                ),
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
