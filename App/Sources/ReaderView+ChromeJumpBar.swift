import NovelCore
import SwiftUI

// 阅读页**章节跳转条**：左端「上一章」、右端「下一章」，中间是本章页码进度条。
//
// 从 `ReaderView+Chrome.swift` 拆出来的（先例：`ReaderView+PageTurn.swift` 从
// `ReaderView.swift` 拆出、`ReaderView+ChromeStyle.swift` 从 `ReaderView+Chrome.swift` 拆出）：
// 那个文件已 580 行、距 SwiftLint `file_length` 600 的 warning 线
// （CI `--strict` 下 warning 即失败）只剩 20 行，装不下进度条；
// 而跳章条是其中**最独立**的一块（只依赖玻璃背景与图标 label，不碰上下栏）。
//
// ⚠️ 拆分只搬代码、不改行为。搬走后取不到 `ReaderView+Chrome.swift` 里那几个**文件级**
// `private` 符号（Swift 的 `private` 是本文件级的）⇒ 该文件里的
// `ReaderChromeEdge` / `ReaderChromeMetrics` / `chromeIconLabel` / `ReaderChromeGlass`
// 已同步放开为**模块内可见**（各自声明处都写了一行放开理由）。
//
// 玻璃语言、尺度常量与图标 label 的**唯一来源**仍在 `ReaderView+Chrome.swift`；
// 本文件只管这一条面板的布局与进度条本身。

// MARK: - 进度条常量

/// 进度条专有的常量（**有名字、带推导**，不散落成魔数）。
private enum ReaderPageScrubberMetrics {
    /// 0.7 —— 常驻页码文字的**降一档**前景不透明度。
    ///
    /// ## 为什么用 `foreground.opacity(...)` 而不是 `.secondary`
    /// 传进来的前景色是按**面板底色**的亮度派生的（`ReaderChromeDerivation.foreground`），
    /// 可能与**应用外观**相反（「深色外观 + 浅色底」时前景是黑的）；而 `.secondary` 跟的是
    /// 应用外观 —— 那种组合下会给出「浅色底 + 浅灰字」，直接不可读。
    ///
    /// ## 0.7 的推导（⚠️ **估算值，需真机复核**）
    /// 前景只有黑 / 白两档，0.7 叠在面板底色上仍远在 `apple-design-2` §6 的 4.5:1 之上：
    /// 深色面板 #1C1C1E（相对亮度 ≈ 0.012）上 70% 白 ⇒ **≈ 8.9:1**；
    /// 浅色面板 #F2F2F7（相对亮度 ≈ 0.891）上 70% 黑 ⇒ **≈ 8.1:1**。
    /// 它与栏内**禁用态**的 0.35 是两个语义（那个是「不可用」，这里是「次要」）。
    static let pageLabelOpacity: Double = 0.7

    /// 0.8 —— 页码文字的**最小缩放比例**（`minimumScaleFactor`）。
    ///
    /// 页码位数多（「第 128 页」+「共 256 页」）或 Dynamic Type 大字号时，这一行宁可**缩字**，
    /// 也不换行、更不把滑块挤到 `minSliderWidth` 以下。0.8 是「还看得清」与「少占宽」的折中：
    /// 再往下缩（如 0.6）小字就接近不可读，不如让它截断（完整页码仍由 `Slider` 的
    /// `.accessibilityValue` 播报）。
    static let pageLabelMinScale: CGFloat = 0.8

    /// 120 —— 滑块的**最小宽度下限**。
    ///
    /// ## 为什么需要
    /// 面板高度必须与上栏 / 下栏一致 ⇒ 页码文字只能与滑块**同排**（见 `ReaderPageScrubber`
    /// 的「布局」），两者在同一行争宽度。不设下限时，长章的三 / 四位数页码会把滑块压到拖不动。
    ///
    /// ## 120 的推导（375pt 宽机型 —— 可运行 iOS 17 的最窄机型）
    /// 375 − 2×`panelOuterMargin`(16) = 343 − 2×`barInnerPadding`(12) = 319
    /// − 2×44（两个跳章按钮的 44pt 命中区）= 231
    /// − 2×`Spacing.xs`(8)（进度条两侧给拇指外伸留的空白）= **215pt** 分给「滑块 + 页码文字」。
    ///
    /// 页码两段 `.caption2`（11pt）按「汉字 1em = 11pt、数字 ≈ 0.6em = 6.6pt、空格 ≈ 0.26em = 2.9pt」
    /// 估（⚠️ **估算值，需真机复核**），两段之间再加 `Spacing.xxs`(4)：
    /// - 三位数：「第 128 页」≈ 47.6 +「共 256 页」≈ 47.6 + 4 ≈ **99pt** ⇒ 滑块本可拿 116pt；
    /// - 四位数：「第 1024 页」≈ 54.2 ×2 + 4 ≈ **112pt** ⇒ 滑块只剩 103pt。
    ///
    /// 取 **120** 后：三位数时页码缩到 ≈ 0.96，四位数时缩到 ≈ 0.85（仍 ≥ 0.8 ⇒ 不截断）
    /// —— 两种常见情况都既保住滑块、又不丢字。
    ///
    /// ## 兜不住时会发生什么（不留「滑块被挤成 0 宽」的隐患）
    /// 这一条面板的**硬最小宽度** = 44 +（8 + 120 + ≈15）+ 44 + 2×12 + 2×16 ≈ **295pt**
    /// （≈15pt 是页码文字截断成「…」时的下限）⇒ 比最窄的 iOS 17 机型（320pt）还窄，
    /// 结构上**不可能溢出**屏幕。再窄的情况（大字号 AX + 四位数页码）依次降级为：
    /// ① 页码文字按 `pageLabelMinScale` 缩到 0.8；② 仍不够则 `lineLimit(1)` **截断**页码文字。
    /// 滑块任何情况下都 ≥ 120pt。
    static let minSliderWidth: CGFloat = 120
}

// MARK: - 本章页码进度条

/// 本章页码进度条：**拖动即时跳页**（手指拖到哪一页，就立刻翻到那一页）。
///
/// ## 为什么用系统 `Slider`
/// 原生可拖，自带 VoiceOver「可调整」语义与 Dynamic Type 适配；自绘轨道 / 拇指就得自己
/// 处理拇指几何、44pt 命中区与无障碍增减手势 —— 三样都容易做漏。
///
/// ## 实时跳页：只发「真的变了」的页码
/// 一次拖动会连续产生上百个 `Double`。每个都发就是同一页被重复发几十次
/// （`.goToPage` 虽不落盘，但每次都会走一遍 reducer 与视图重算）⇒
/// `set` 里先取整、再与**上次已发的页码**比较，只有真的变了才 `onJump`。
///
/// ## 跟手：显示值由本地 `@State` 承载
/// `scrubbingValue`（`nil` = 手指没在条上）优先于 `pageIndex`：若只依赖 reducer 往返，
/// 快速拖动时状态回传滞后于手指，滑块会「跳回去」。
///
/// ## 松手
/// `onEditingChanged(false)` 时调**一次** `onCommit()`（把当前位置落盘一次），
/// 并清空本地拖动值 ⇒ 之后显示值重新由 `pageIndex` 驱动。
///
/// ## 布局：**单行**（滑块 + 常驻页码同排）
/// 面板高度必须与上栏 / 下栏**逐值一致**（12 + 44 + 12 = 68pt）⇒ 这一条只能有一行内容：
/// 常驻页码与滑块**同一行**（旧版是「滑块一行 + 页码一行」的 `VStack`，比另两条高约 17pt）。
/// 宽度不够时由 `ReaderPageScrubberMetrics.minSliderWidth` 兜底 —— 让页码文字先缩放、再截断，
/// 滑块不会被挤没（推导见那个常量）。
///
/// ## 降级（由调用方负责）
/// `pageCount <= 1`（单页章 / 正文还没排完）时本视图**不渲染**（调用方放回 `Spacer`）：
/// 单页章没有「拖到第几页」这回事，置灰一个永远拖不动的控件比不显示更糟。
///
/// ## 自包含
/// 不依赖 `ReaderView` / `ReaderChromeStyle` 的内部成员，只吃 `foreground` 一个颜色参数
/// —— 否则拆文件后又要连带放开一批可见性。
struct ReaderPageScrubber: View {
    /// 当前页码（0 基）。调用方只在 `pageCount > 1` 时构造本视图 ⇒ 不会是 `-1`。
    let pageIndex: Int
    /// 本章总页数（调用方保证 > 1）。
    let pageCount: Int
    /// 前景色（来自 `ReaderChromeStyle.foreground`，已按面板底色的亮度派生）。
    let foreground: Color
    /// 拖到第 N 页（0 基）——**高频**调用；实现方只迁移位置、不落盘。
    var onJump: (Int) -> Void
    /// 手指抬起：落盘一次。
    var onCommit: () -> Void

    /// 拖动中的本地值；`nil` = 手指没在条上 ⇒ 显示真实页码。
    @State private var scrubbingValue: Double?
    /// 最近一次**已经发出**的页码；`nil` = 本次拖动还没发过。
    @State private var lastSentPage: Int?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Slider(
                value: value,
                in: 0 ... Double(max(0, pageCount - 1)),
                step: 1,
                onEditingChanged: editingChanged
            )
            .tint(foreground)
            // `Slider` 固有高度约 31pt，低于 HIG 的 44pt 触控下限（`apple-design-2` §9）⇒ 补足。
            // 44 的唯一来源是 `ReaderChromeMetrics.minTouchTarget`，不在这里另写一个数。
            //
            // 宽度下限是**硬下限**（见 `ReaderPageScrubberMetrics.minSliderWidth`）：
            // 它比 `layoutPriority` 可靠 —— 滑块是「给多少吃多少」的弹性视图，若给它更高的
            // layout priority，它会先吃掉整行提案，反而把页码文字压成「…」；
            // 显式 minWidth 则只保证「滑块不被压到 120pt 以下」，宽度够时页码仍拿满自己的理想宽度。
            .frame(
                minWidth: ReaderPageScrubberMetrics.minSliderWidth,
                minHeight: ReaderChromeMetrics.minTouchTarget
            )
            .accessibilityLabel("本章进度")
            .accessibilityValue(spokenPageText)

            pageLabel
        }
        // 拇指约 28pt 宽、居中于轨道值 ⇒ 值到两端时拇指会向外伸出轨道约 14pt，
        // 两侧各留 `Spacing.xs`(8) 才不压到跳章按钮的 44pt 命中区。
        .padding(.horizontal, DesignTokens.Spacing.xs)
    }

    /// 当前**显示**页码（0 基）：拖动中取本地值（与拇指位置一致），否则取真实页码。
    private var displayPageIndex: Int {
        Int((scrubbingValue ?? Double(pageIndex)).rounded())
    }

    /// 常驻页码（与滑块**同一行**）：小字、比前景色降一档
    /// （理由见 `ReaderPageScrubberMetrics.pageLabelOpacity`）。
    ///
    /// 字号用**文本样式** `.caption2`（默认内容尺寸 11pt，HIG 标签栏文字标准），随 Dynamic Type
    /// 缩放 —— 不用固定字号 `Font.system(size:)`（大字号无障碍设置下会被裁）。
    /// `.font` 施加在这个 `HStack` 上即可：它与 `.lineLimit` / `.minimumScaleFactor` 一样
    /// 走环境向子 `Text` 传播（`.caption2` 是既有写法，不新增第二种施加方式）。
    ///
    /// 宽度不够时**先缩字、再截断**（`pageLabelMinScale` / `lineLimit(1)`），绝不换行 ——
    /// 换行会把这一条顶高，三条面板就不再同高（见 `ReaderChapterJumpBar` 的几何注释）。
    ///
    /// 对 VoiceOver 隐藏：这两段文字是**视觉**补充，语义已由 `Slider` 的
    /// `.accessibilityValue` 播报（截断时也仍播报完整页码）；不隐藏会被读成两遍。
    private var pageLabel: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Text("第 \(displayPageIndex + 1) 页")
            Text("共 \(pageCount) 页")
        }
        .font(.caption2)
        .foregroundStyle(foreground.opacity(ReaderPageScrubberMetrics.pageLabelOpacity))
        .lineLimit(1)
        .minimumScaleFactor(ReaderPageScrubberMetrics.pageLabelMinScale)
        .accessibilityHidden(true)
    }

    /// VoiceOver 播报的页码：与常驻文字同源同口径（读到什么就看到什么）。
    /// 不给它这个值，`Slider` 会按百分比读成一串小数（如「0.27」）。
    private var spokenPageText: String {
        "第 \(displayPageIndex + 1) 页，共 \(pageCount) 页"
    }

    /// 显示值：拖动中走本地值（跟手），否则走真实页码。
    private var value: Binding<Double> {
        Binding(
            get: { scrubbingValue ?? Double(pageIndex) },
            set: { newValue in
                scrubbingValue = newValue
                let page = Int(newValue.rounded())
                // 只有**取整后的页码真的变了**才发：一次拖动会连续产生上百个 Double，
                // 每个都发就是同一页被重复发几十次。
                guard page != lastSentPage else { return }
                lastSentPage = page
                onJump(page)
            }
        )
    }

    /// 手指按下 / 抬起。抬手时落盘一次，并把显示值交回 `pageIndex` 驱动。
    private func editingChanged(_ isEditing: Bool) {
        guard !isEditing else { return }
        onCommit()
        scrubbingValue = nil
        lastSentPage = nil
    }
}

// MARK: - 跳章条参数包

/// 跳章条中间那条进度条所需的**状态 + 回调**。
///
/// ## 为什么收成一个值类型
/// `ReaderChapterJumpBar` 已有 4 个参数（style / 上一章 / 下一章 / 跳章回调），
/// 再加 4 个就越过 SwiftLint `function_parameter_count` 的 warning 5
/// （CI `--strict` 下 warning 即失败）；收成一个参数后它仍是 5 个，
/// 且 `ReaderChromeOverlay` 与 `ReaderView.body` 也各只多一个参数。
struct ReaderPageJump {
    /// 当前页码（0 基）；`pages` 为空时是 `-1`（此时 `pageCount` 也 ≤ 1 ⇒ 不渲染进度条）。
    var pageIndex: Int
    /// 本章总页数。
    var pageCount: Int
    /// 拖到第 N 页（0 基，**高频**）—— 只迁移位置、不落盘。
    var onJumpToPage: (Int) -> Void
    /// 拖动结束（抬手）：把当前位置落盘一次。
    var onCommitPageJump: () -> Void
}

// MARK: - 章节跳转条

/// 下栏**正上方**的章节跳转条：左端「上一章」、右端「下一章」，中间是本章页码进度条。
///
/// ## 几何
/// - **宽度**：与上栏 / 下栏同宽 —— 三者都在 `ReaderChromeOverlay` 的同一个 `VStack` 里，
///   共用同一份左右安全区内缩与 `ReaderChromeMetrics.panelOuterMargin`。
/// - **高度**：与上栏 / 下栏**逐值相同** —— 内容行 44（`ReaderChromeMetrics.minTouchTarget`）
///   + 上下各 `panelVerticalPadding`(12) = **68pt**。常驻页码已并入同一行
///   （见 `ReaderPageScrubber` 的「布局」），不再多占一行；旧版是「滑块 + 页码」两行 ⇒ 约 85pt，
///   比另两条高约 17pt。Dynamic Type 长大时三条一起长（页码不再是额外的固定增量）。
/// - **位置**：紧贴下栏上方，中间留 `DesignTokens.Spacing.xs`(8pt) 的空隙 ——
///   两条面板**各自独立**（各有自己的 0.5pt 边缘线与柔影），8pt 间隙让「这是另一条」一眼可辨。
///
/// ## 为什么用 `edge: .bottom`
/// 本条的内容（图标）在条**上方**，与下栏同侧 ⇒ 用同一条边语义：边缘线朝上、柔影向上扩散。
///
/// ⚠️ 玻璃**没有**渐变羽化了（2026-10-11 移除，理由见 `ReaderChromeGlass`）——
/// 三条面板因此逐像素同色。本条另外在 `ReaderChromeOverlay` 里吃一个 `.zIndex(1)`：
/// 下栏的柔影会向上扩约 17pt，而两条面板只隔 8pt ⇒ 不抬高就会被压暗下半截。
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
struct ReaderChapterJumpBar: View {
    let style: ReaderChromeStyle
    /// 相邻章节；`nil` = 到边界（首章的上一章 / 末章的下一章），对应按钮置灰。
    let previousChapter: ChapterItem?
    let nextChapter: ChapterItem?
    var onJumpToChapter: (ChapterItem) -> Void
    /// 中间进度条的状态与回调（见 `ReaderPageJump`）。
    var pageJump: ReaderPageJump

    var body: some View {
        HStack(spacing: 0) {
            jumpButton("上一章", systemImage: "backward.end", chapter: previousChapter)

            // 中间：本章页码进度条。单页章 / 正文还没排完（`pageCount <= 1`）⇒ 放回原来的
            // 空档，不渲染一个永远拖不动的控件（降级理由见 `ReaderPageScrubber`）。
            if pageJump.pageCount > 1 {
                ReaderPageScrubber(
                    pageIndex: pageJump.pageIndex,
                    pageCount: pageJump.pageCount,
                    foreground: style.foreground,
                    onJump: pageJump.onJumpToPage,
                    onCommit: pageJump.onCommitPageJump
                )
            } else {
                Spacer(minLength: 0)
            }

            jumpButton("下一章", systemImage: "forward.end", chapter: nextChapter)
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
