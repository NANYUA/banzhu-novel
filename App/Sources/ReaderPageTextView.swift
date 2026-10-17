import NovelCore
import NovelPagination
import SwiftUI
import UIKit

/// 渲染盒 ≠ 分页盒时把**真实盒**送回 reducer 的回调（由 `ReaderView` 注入，见
/// `EnvironmentValues.readerBoxMismatchHandler`）。
///
/// 为什么走环境而不是构造参数：`PageTextView` 有**两处**构造点（`ReaderView.singlePage` 与
/// `ReaderView+PageGesture.panPage`），而平移翻页是**默认路径** —— 逐点传参必须同时改两处
/// （漏一处就只在兜底路径生效）；环境值对两处一视同仁，且不动任何构造点。
private struct ReaderBoxMismatchKey: EnvironmentKey {
    static let defaultValue: ((CGSize) -> Void)? = nil
}

extension EnvironmentValues {
    /// 渲染盒 ≠ 分页盒时的确定性回写（`ReaderView` 里转成 `viewStore.send(.containerSizeChanged)`）。
    var readerBoxMismatchHandler: ((CGSize) -> Void)? {
        get { self[ReaderBoxMismatchKey.self] }
        set { self[ReaderBoxMismatchKey.self] = newValue }
    }
}

/// 单页 `UITextView` 包装（UIKit 承载，SwiftUI 里用 `UIViewRepresentable`）。
///
/// `PageTurnMode` 只剩 `.slide`：恒为单页渲染，滚动恒关闭。
struct PageTextView: UIViewRepresentable {
    let text: String
    let configuration: PaginationConfiguration

    /// 本页是否**从段落开头**开始（由切片函数调 NovelCore 的 `ParagraphBoundary` 判定后传入）。
    ///
    /// 为 `false` 时本页第一行是**续行**（本页从段落中间开始），不加首行缩进；
    /// 只影响本页**第一个段落**，本页后续段落照旧加缩进。
    let startsAtParagraphStart: Bool

    /// 本页是否**章首第一页**（第一段就是章标题）。
    ///
    /// 章标题在正文文本里就是第一段（`ReaderFeature.displayText` = 章名 + `"\n\n"` + 正文），
    /// 香色闺阁给标题单独一套字号 / 字重 / 字距 / 行距 / 段距，这里照搬：
    /// 为 `true` 时第一段套 `ReadingTextAttributes.title(configuration:)`。
    ///
    /// ⚠️ 必须与度量侧 `TextKitMeasuring` 的判据一致（它用 `from == 0`）：两边不同步就会
    /// 度量盒与渲染盒错位（B0-2 几何契约）。
    let showsChapterTitle: Bool

    /// 渲染盒 ≠ 分页盒时的回写回调（见 `ReaderBoxMismatchKey`）。
    ///
    /// ⚠️ 刻意**不写 `private`**：`private` 存储属性会让**隐式 memberwise 初始化器**变成
    /// `private`（Swift 规则），而本结构体在 `ReaderView` 与 `ReaderView+PageGesture` 两个文件里
    /// 构造 —— 那会直接编译不过。下面另写了显式 `init`，把这条歧义彻底去掉。
    @Environment(\.readerBoxMismatchHandler) var onBoxMismatch: ((CGSize) -> Void)?

    /// 显式初始化器：只吃四个渲染输入（环境值由 SwiftUI 注入，不参与构造）。
    init(
        text: String,
        configuration: PaginationConfiguration,
        startsAtParagraphStart: Bool,
        showsChapterTitle: Bool = false
    ) {
        self.text = text
        self.configuration = configuration
        self.startsAtParagraphStart = startsAtParagraphStart
        self.showsChapterTitle = showsChapterTitle
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context _: Context) -> PageBoxTextView {
        let textView = PageBoxTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        // 文本容器宽 = frame.width − textContainerInset 左右：显式钉住，不吃 UIKit 默认值。
        textView.textContainer.widthTracksTextView = true
        // 视图盒之外**一律不画**：正文盒（= 下边距的线）之下不许出现正文。
        // 高度那半由 `PageBoxTextView` 封顶到分页盒兑现，这里是最后一道兜底。
        textView.clipsToBounds = true
        // 分页盒（容器高的上限 + 「渲染盒是否等于分页盒」的比较基准）。
        textView.paginatedBoxSize = configuration.containerSize
        textView.onBoxMismatch = onBoxMismatch
        return textView
    }

    func updateUIView(_ uiView: PageBoxTextView, context: Context) {
        context.coordinator.parent = self

        // ⚠️ 这两项**先于**下面的内容比较写：盒不匹配的回写恰恰要覆盖「内容没变、只是盒还没落定」
        // 那条路径（`guard contentChanged` 之后才写就会漏掉它）。
        uiView.paginatedBoxSize = configuration.containerSize
        uiView.onBoxMismatch = onBoxMismatch

        let contentChanged = context.coordinator.appliedText != text
            || context.coordinator.appliedConfiguration != configuration
            // 它由 `text` + 分页决定，正常不会单独变；但它是**渲染输出**的一个输入，
            // 漏比就会出现「正文没变、缩进却是上一页口径」的陈旧渲染。
            || context.coordinator.appliedStartsAtParagraphStart != startsAtParagraphStart
        guard contentChanged else { return }

        context.coordinator.appliedText = text
        context.coordinator.appliedConfiguration = configuration
        context.coordinator.appliedStartsAtParagraphStart = startsAtParagraphStart

        // `PageTurnMode` 只剩 `.slide`：永远是单页渲染，滚动恒关闭。
        uiView.isScrollEnabled = false
        uiView.textContainer.lineFragmentPadding = 0
        // 上面关掉了 `isScrollEnabled`（UITextView 会因此重配文本容器），此处重新钉一次宽度不变量。
        // 高度**封顶到分页盒**（下方 `pinTextContainerToBounds()`）：容器高 = min(bounds − 竖向 inset,
        // `containerSize.height`)。owner 真机复测「正文内容还是会越过下边距标线」证明**只钉
        // `bounds.height` 不够** —— 非滚动 `UITextView` 的固有高 = **内容高**，SwiftUI 给它的 frame
        // 可能比正文盒高 ⇒ `bounds` 本身就是那个出界的盒，钉在它上面等于没钉（`clipsToBounds` 也
        // 救不了：正文在视图**内**，只是视图比盒高）⇒ 上限必须取**度量侧排版用的同一个高**。
        // ⚠️ 旧注释（「高度不钉：手动设定属未验证改动」）已被两轮真机反馈推翻：不封顶就出界。
        // ⛔ 别再退回不钉，也别只钉 `bounds.height`。
        // ⚠️ 但封顶**只管住「渲染容器不比度量容器高」**：`NSTextContainer` 的高度只是行片段**起点**
        // 的上限，起点在盒内、底边越出的那一行照样会被排出来 ⇒ 那一行必须由**度量侧退行**处理
        // （`TextKitMeasuring.trimmedGlyphRange`），见 `PageBoxTextView` 的文档注释。
        uiView.textContainer.widthTracksTextView = true
        // 竖向 inset 恒为 **0**（2026-10-11 语义变更）：`PageInset.top/bottom` 现在是
        // 「**距屏幕边缘的绝对距离**」（`0` = 贴屏幕边、不避让刘海），由 `ReaderView` 的布局
        // padding 兑现，并且**已经**从盒高里扣掉（盒高 = 全屏高 − top − bottom
        // = `configuration.containerSize.height`，见 `readerContentPaddings` /
        // `readerContentSize`，B0-2 几何契约）⇒ 这里再按 inset 起排就是**两处都算**、边距翻倍。
        // 旧实现（U9-7）是「外层管负值、内层管正值」的两段式，负值在这里被 clamp 成 0 —— 那套已废弃。
        // 左右**不动**：仍是「安全区盒内再减左右边距」，正值语义未变。
        uiView.textContainerInset = UIEdgeInsets(
            top: 0,
            left: configuration.inset.leading,
            bottom: 0,
            right: configuration.inset.trailing
        )
        uiView.pinTextContainerToBounds()
        uiView.backgroundColor = configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor,
            customDark: configuration.customBackgroundColorDark
        )
        uiView.attributedText = makeAttributedString()
    }

    /// 把渲染盒钉死在**父级提案**（可用盒）上，而不是让 SwiftUI 按 `UITextView` 自己的尺寸协商定 frame 宽。
    ///
    /// 不实现本方法时宽度可能与父级可用盒不等（宽出来时，文本容器跟着变宽 → 每行左右越界被屏边裁掉）。
    /// 返回提案后 `frame.width` 恒等于父级可用宽，与 `TextKitMeasuring` 度量用的
    /// `configuration.containerSize.width` 是同一个值（B0-2 几何契约）。
    /// 高度同理：返回的盒高 = 父级可用高 = `configuration.containerSize.height`（`ReaderView`
    /// 那层的 `.frame(width:height:)` 已把可用盒钉成分页盒）⇒ 与 `TextKitMeasuring` 的容器高同源。
    /// ⚠️ 这里**不做** `min(提案, 盒)` 的封顶：那会在「配置尺寸还没同步过来」的首帧把盒缩小
    /// （配置默认 320×480）⇒ 页面被居中缩小、首帧闪一下；盒不同步由 `PageBoxTextView` 的
    /// **确定性回写**（`reportBoxMismatchIfNeeded()`）修，而不是靠把渲染盒改小。
    /// 「末行越盒」的根因在**度量侧**（`TextKitMeasuring.trimmedGlyphRange` 逐行回退，那一行落到
    /// 下一页）；`PageBoxTextView` 的容器封顶与 `ReaderView.readerContent` 的 `.clipped()` 只是兜底。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: PageBoxTextView,
        context _: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: configuration.containerSize)
    }

    /// 本页正文的 attributed string。
    ///
    /// ⚠️ 属性**不在本文件手写**：统一走 NovelPagination 的 `ReadingTextAttributes`
    /// （度量侧 `TextKitMeasuring` 用的是同一份），两份手抄必然漂 —— 每页多塞 / 少塞正文、
    /// 正文被裁（B0-2 几何契约）。本文件只负责**颜色**（要按背景明暗解析）与
    /// 「第一段是续行 / 章标题」这两处局部覆盖。
    private func makeAttributedString() -> NSAttributedString {
        let backgroundColor = configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor,
            customDark: configuration.customBackgroundColorDark
        )
        var attributes = ReadingTextAttributes.body(
            configuration: configuration,
            firstLineHeadIndent: configuration.firstLineHeadIndent
        )
        attributes[.foregroundColor] = configuration.textColorMode.uiColor(
            on: backgroundColor,
            custom: configuration.customTextColor
        )
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)

        let firstParagraph = NSRange(
            location: 0,
            length: ParagraphBoundary.firstParagraphUTF16Length(in: text)
        )
        if !startsAtParagraphStart {
            // 本页从**段落中间**开始时，第一行是续行，不该有首行缩进。
            // ⚠️ 只换掉切片**第一个段落**那一份样式；本页后续段落照旧带缩进。
            attributed.addAttribute(
                .paragraphStyle,
                value: ReadingTextAttributes.paragraphStyle(
                    lineSpacing: configuration.lineSpacing,
                    paragraphSpacing: configuration.paragraphSpacing,
                    firstLineHeadIndent: 0
                ),
                range: firstParagraph
            )
        } else if showsChapterTitle {
            // 章首第一页：第一段是章标题，换掉字号 / 字重 / 字距 / 行距 / 段距（颜色保留）。
            attributed.addAttributes(
                ReadingTextAttributes.title(configuration: configuration),
                range: firstParagraph
            )
        }
        return attributed
    }

    final class Coordinator: NSObject {
        var parent: PageTextView
        var appliedText: String?
        var appliedConfiguration: PaginationConfiguration?
        var appliedStartsAtParagraphStart: Bool?

        init(parent: PageTextView) {
            self.parent = parent
        }
    }
}

/// 正文盒 `UITextView`：把**文本容器**钉死在正文盒内（高度这半；宽度那半由
/// `widthTracksTextView` 维护，见 `PageTextView.makeUIView`），并在**渲染盒与分页盒不一致时
/// 把真实盒回写出去**（时序缺陷的确定性修复，见 `reportBoxMismatchIfNeeded()`）。
///
/// ## 为什么容器高要**封顶到分页盒**（owner 真机前几轮反馈）
/// - 只把容器高钉到 `bounds.height`（「视图盒高」）时真机复测**没生效**。原因是这条等式的前提
///   「`bounds` == 正文盒」**不成立** —— 非滚动 `UITextView` 的固有高度是**内容高**，SwiftUI 给它的
///   frame 可能比正文盒高 ⇒ `bounds.height` 本身就是那个「出界的盒」，钉在它上面等于没钉；
///   `clipsToBounds` 也救不了（正文在**视图内**，只是视图比盒高）。
/// - 上限取**分页盒**：`min(bounds − 竖向 inset, configuration.containerSize.height)`。
///   `containerSize.height` 就是 `TextKitMeasuring` 排版时用的那个高（= 边框标线所在盒的高）
///   ⇒ 渲染容器**不会比度量容器高**，不会多排正文。
/// - ⚠️ 但「容器不超高」**不等于**「没有一行越盒」：`NSTextContainer` 的高度只是行片段**起点**的
///   上限，起点在盒内、底边越出的那一行仍会被排出来。根因修在**度量侧**
///   （`TextKitMeasuring.trimmedGlyphRange` 逐行回退 ⇒ 那一行落到下一页）；本类的容器封顶与
///   `ReaderView.readerContent` 的 `.clipped()` 只作**最后兜底**。
///
/// ## 为什么在 `layoutSubviews` 里钉（而不是只在 `updateUIView` 里设一次）
/// `updateUIView` 在**内容未变**时直接 return（见它的 `guard contentChanged`），而 frame 会随
/// 字号 / 边距 / 容器尺寸变化 —— 这条「只变尺寸、不变内容」的路径不经过它。`layoutSubviews`
/// 是 frame 落定后 UIKit 必然调用的钩子，两条路径都由它兜住；`updateUIView` 里也在
/// `textContainerInset` 之后显式调一次，让「内容变化」那条路径不依赖后续的布局回调。
final class PageBoxTextView: UITextView {
    /// 分页时用的正文盒（`PaginationConfiguration.containerSize`）。由 `PageTextView` 在
    /// `makeUIView` / `updateUIView` 里写入。两个用途：
    /// 1. 文本容器高的**上限**（`pinTextContainerToBounds()`）；
    /// 2. 与**真实渲染盒**（`bounds.size`）逐值比较的基准（`reportBoxMismatchIfNeeded()`）。
    var paginatedBoxSize: CGSize = .zero

    /// 渲染盒 ≠ 分页盒时把**真实盒**回写出去（由 `PageTextView` 从环境注入 ⇒ `ReaderView` 里
    /// 转成 `viewStore.send(.containerSizeChanged(_:))`）。
    var onBoxMismatch: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        pinTextContainerToBounds()
        reportBoxMismatchIfNeeded()
    }

    /// 容器高 = `min(视图 bounds 高 − textContainerInset 竖向, 分页盒高)`（竖向 inset 本 App 恒 0）。
    ///
    /// 只改**高度**：宽度那半仍由 `widthTracksTextView = true` 维护（= `TextKitMeasuring` 的
    /// `containerSize.width − inset.leading − inset.trailing`，同源，⛔ 别在这里碰宽度）。
    /// 高度**只在需要时**写一次：避免在 `layoutSubviews` 里无条件写容器尺寸引发二次布局。
    func pinTextContainerToBounds() {
        textContainer.heightTracksTextView = false
        // 每轮重申：`clipsToBounds` 是最后一道兜底，别被 UIKit 重配容器时清掉。
        clipsToBounds = true
        var height = max(bounds.height - textContainerInset.top - textContainerInset.bottom, 0)
        if paginatedBoxSize.height > 0 {
            height = min(height, paginatedBoxSize.height)
        }
        guard textContainer.size.height != height else { return }
        var size = textContainer.size
        size.height = height
        textContainer.size = size
    }

    /// ## 确定性回写：渲染盒 ≠ 分页盒 ⇒ 把**真实盒**送回 reducer
    ///
    /// owner 真机的决定性线索：**「加上调试面板以后正文内容就不溢出了」** —— 调试面板作为子视图
    /// 多触发了一次布局，那一次让盒尺寸落定 ⇒ 溢出消失。⇒ 真因不是「差几个 pt」，而是**时序**：
    /// 某一帧里 `bounds`（真实渲染盒）还没落定、或配置里的 `containerSize` 还是旧值（含首次分页
    /// 时 State 的默认 `320×480`），分页就按**错的那个盒**算 ⇒ 页内多装一行 ⇒ 越出下边距标线。
    ///
    /// 这里不再依赖 `.onChange(of: contentSize)` 的触发时机（它只在尺寸**变化**时修；配置被旧值
    /// 覆写、而尺寸没变时它不修）：`layoutSubviews` 是「frame 落定后必然调用」的钩子，每帧拿
    /// **真实盒**与**分页盒**比一次，不等就回写 ⇒ 分页一定按真实盒重算。
    ///
    /// ## 为什么不会自激
    /// 回写只送一个 action（`containerSizeChanged`），reducer 侧 `applyContainerSize`
    /// （`ReaderFeature.swift`）自带 `guard state.config.containerSize != size else { return }`
    /// ⇒ 同尺寸**不发状态变更**、不重渲染；而回写送的就是本帧 `bounds.size`，下一帧比较时
    /// `paginatedBoxSize` 已经等于它 ⇒ **一次修正后收敛**。若之后又被 `.settingsLoaded` /
    /// `.configChanged` 用旧值覆写，下一帧再修一次，仍然收敛。⛔ 这里不直接改 SwiftUI 状态、
    /// 也不重排文本，只送这一个 action。
    private func reportBoxMismatchIfNeeded() {
        // bounds 还没落定（0）时不许回写：那会把「空盒」当成真实盒送进分页。
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard bounds.size != paginatedBoxSize else { return }
        onBoxMismatch?(bounds.size)
    }
}
