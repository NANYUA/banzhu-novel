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
    /// 传进来的前景色是按**染色后玻璃**的亮度派生的（`ReaderChromeDerivation.foreground`），
    /// 可能与**应用外观**相反（「深色外观 + 浅色底」时前景是黑的）；而 `.secondary` 跟的是
    /// 应用外观 —— 那种组合下会给出「浅色底 + 浅灰字」，直接不可读。
    ///
    /// ## 0.7 的推导（⚠️ **估算值，需真机复核**）
    /// 前景只有黑 / 白两档，0.7 叠在玻璃上仍在 `apple-design-2` §6 的 4.5:1 之上：
    /// 深色玻璃 #3C3C3F（相对亮度 ≈ 0.046）上 70% 白 ≈ **6.3:1**；
    /// 浅色玻璃（亮度 ≈ 0.84）上 70% 黑 ≈ **7.0:1**。
    /// 它与栏内**禁用态**的 0.35 是两个语义（那个是「不可用」，这里是「次要」）。
    static let pageLabelOpacity: Double = 0.7
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
    /// 前景色（来自 `ReaderChromeStyle.foreground`，已按染色后玻璃的亮度派生）。
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
        VStack(spacing: DesignTokens.Spacing.xxs) {
            Slider(
                value: value,
                in: 0 ... Double(max(0, pageCount - 1)),
                step: 1,
                onEditingChanged: editingChanged
            )
            .tint(foreground)
            // `Slider` 固有高度约 31pt，低于 HIG 的 44pt 触控下限（`apple-design-2` §9）⇒ 补足。
            // 44 的唯一来源是 `ReaderChromeMetrics.minTouchTarget`，不在这里另写一个数。
            .frame(minHeight: ReaderChromeMetrics.minTouchTarget)
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

    /// 常驻页码行：小字、比前景色降一档（理由见 `ReaderPageScrubberMetrics.pageLabelOpacity`）。
    ///
    /// 字号用**文本样式** `.caption2`（默认内容尺寸 11pt，HIG 标签栏文字标准），随 Dynamic Type
    /// 缩放 —— 不用固定字号 `Font.system(size:)`（大字号无障碍设置下会被裁）。
    ///
    /// 对 VoiceOver 隐藏：这两段文字是**视觉**补充，语义已由 `Slider` 的
    /// `.accessibilityValue` 播报；不隐藏会被读成两遍。
    private var pageLabel: some View {
        HStack(spacing: 0) {
            Text("第 \(displayPageIndex + 1) 页")
            Spacer(minLength: 0)
            Text("共 \(pageCount) 页")
        }
        .font(.caption2)
        .foregroundStyle(foreground.opacity(ReaderPageScrubberMetrics.pageLabelOpacity))
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
/// - **高度**：**比上下栏高一档**。内容行（44）与上下各 12 内边距与上下栏同源，但中间多了
///   进度条下面那一行常驻页码（`Spacing.xxs` + `.caption2` ≈ 17pt）⇒ 默认内容尺寸下约 85pt
///   （上下栏 68pt）。这是「常驻一行页码」这条需求的必然结果；Dynamic Type 长大时三条一起长。
/// - **位置**：紧贴下栏上方，中间留 `DesignTokens.Spacing.xs`(8pt) 的空隙 ——
///   两条面板**各自独立**（各有自己的 0.5pt 边缘线与柔影），8pt 间隙让「这是另一条」一眼可辨。
///
/// ## 为什么用 `edge: .bottom`
/// 本条的内容（图标）在条**上方**，与下栏同侧 ⇒ 用同一条边语义：边缘线朝上、
/// 柔影向上扩散、羽化朝上淡出。
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
