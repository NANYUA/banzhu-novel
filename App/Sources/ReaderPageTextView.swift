import NovelCore
import NovelPagination
import SwiftUI
import UIKit

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
        // 高度那半由 `PageBoxTextView` 钉住容器兑现，这里是最后一道兜底。
        textView.clipsToBounds = true
        return textView
    }

    func updateUIView(_ uiView: PageBoxTextView, context: Context) {
        context.coordinator.parent = self

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
        // 高度**也钉**（下方 `textContainerInset` 之后那次 `pinTextContainerToBounds()`，
        // 尺寸变化那条路径由 `PageBoxTextView.layoutSubviews` 兜住）：不钉时 UITextView 会
        // **按内容自己撑高**文本容器，排版盒可能**高于**一页的正文盒 ⇒ 正文被排到正文盒底边
        // （= 下边距的线）之外。owner 真机反馈「下边距的线外也会有正文文本」就是这条路径的结果。
        // ⚠️ 旧注释（「高度不钉：容器高由 UITextView 自己维护；手动设定属未验证改动」）已被该反馈推翻：
        // 现在有验证了 —— 不钉就出界，钉住才有「正文恒在正文盒内」这个不变量。⛔ 别再退回不钉。
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
        // 钉容器高度 = 视图盒高 − 竖向 inset（竖向恒 0）⇒ 容器高 = 一页的正文盒高，
        // 与 `TextKitMeasuring` 度量时用的 `configuration.containerSize.height` 是同一个值。
        // 必须在 `textContainerInset` **之后**算，否则用的是上一份 inset。
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
    /// 高度同理：返回的盒高就是父级可用高（= `configuration.containerSize.height`，
    /// 与 `TextKitMeasuring` 的容器高同源）；`PageBoxTextView` 把文本容器**钉在这个高度**上，
    /// 正文因此排不出这个盒 —— 下边距的线外不再出现正文（owner 真机反馈，见该类的文档注释）。
    /// 提案未指定尺寸的场合（首次测量）用 `containerSize` 兜底，保证与度量盒同源。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: PageBoxTextView,
        context _: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: configuration.containerSize)
    }

    /// 本页正文的 attributed string。
    ///
    /// ⚠️ 与度量侧 `Packages/NovelPagination/Sources/NovelPagination/TextKitMeasuring.swift`
    /// 是**同一条口径**（段落样式逐字段同值 + 首行缩进的抑制规则同源，都调 `ParagraphBoundary`）：
    /// 改一处必须改另一处，否则度量盒与渲染盒错位 —— 每页多塞 / 少塞正文，正文被裁
    /// （B0-2 几何契约）。
    private func makeAttributedString() -> NSAttributedString {
        let backgroundColor = configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor,
            customDark: configuration.customBackgroundColorDark
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ReadingFontFactory.makeFont(configuration: configuration),
            .paragraphStyle: makeParagraphStyle(
                firstLineHeadIndent: configuration.firstLineHeadIndent
            ),
            .kern: configuration.characterSpacing,
            .foregroundColor: configuration.textColorMode.uiColor(
                on: backgroundColor,
                custom: configuration.customTextColor
            ),
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)

        // 本页从**段落中间**开始时，第一行是续行，不该有首行缩进。
        // ⚠️ 只换掉切片**第一个段落**那一份样式；本页后续段落照旧带缩进。
        if !startsAtParagraphStart {
            attributed.addAttribute(
                .paragraphStyle,
                value: makeParagraphStyle(firstLineHeadIndent: 0),
                range: NSRange(
                    location: 0,
                    length: ParagraphBoundary.firstParagraphUTF16Length(in: text)
                )
            )
        }
        return attributed
    }

    /// 段落样式：`firstLineHeadIndent` 单独作参数，**其余字段与度量侧逐值一致**
    /// （`TextKitMeasuring.swift` 的 `makeParagraphStyle`）—— 两处必须同时改。
    ///
    /// `firstLineHeadIndent` 传 `0` 就是「本行不加首行缩进」：缩进宽度本身仍只有
    /// `PaginationConfiguration.firstLineHeadIndent` 一个来源，这里不引入第二个宽度。
    private func makeParagraphStyle(firstLineHeadIndent: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = configuration.lineSpacing
        style.paragraphSpacing = configuration.paragraphSpacing
        style.firstLineHeadIndent = firstLineHeadIndent
        return style
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

/// 正文盒 `UITextView`：把**文本容器**钉死在视图盒内（高度这半；宽度那半由
/// `widthTracksTextView` 维护，见 `PageTextView.makeUIView`）。
///
/// ## 为什么必须钉高度（owner 真机反馈）
/// owner 打开阅读设置里的「正文边框标识」后看到：**下边距的线外也会有正文文本**。
/// 根因是高度这半一直没钉 —— 关掉 `isScrollEnabled` 后 `UITextView` 会**按内容自己撑高**
/// 文本容器，排版盒因此可能**高于**一页的正文盒 ⇒ 正文被排到正文盒底边（= 下边距的线）之下。
/// 旧注释「高度不钉 / 手动设定属未验证改动」已被这条真机反馈推翻：**不钉就是出界**。
///
/// ## 为什么钉在 `layoutSubviews` 里（而不是只在 `updateUIView` 里设一次）
/// `updateUIView` 在**内容未变**时直接 return（见它的 `guard contentChanged`），而 frame 会随
/// 字号 / 边距 / 容器尺寸变化 —— 这条「只变尺寸、不变内容」的路径不经过它。`layoutSubviews`
/// 是 frame 落定后 UIKit 必然调用的钩子，两条路径都由它兜住；`updateUIView` 里也在
/// `textContainerInset` 之后显式调一次，让「内容变化」那条路径不依赖后续的布局回调。
final class PageBoxTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        pinTextContainerToBounds()
    }

    /// 容器高 = 视图 bounds 高 − `textContainerInset` 竖向（本 App 恒 0，见 `PageTextView.updateUIView`）。
    ///
    /// 只改**高度**：宽度那半仍由 `widthTracksTextView = true` 维护（= `TextKitMeasuring` 的
    /// `containerSize.width − inset.leading − inset.trailing`，同源，⛔ 别在这里碰宽度）。
    /// 高度**只在需要时**写一次：避免在 `layoutSubviews` 里无条件写容器尺寸引发二次布局。
    func pinTextContainerToBounds() {
        textContainer.heightTracksTextView = false
        let height = max(bounds.height - textContainerInset.top - textContainerInset.bottom, 0)
        guard textContainer.size.height != height else { return }
        var size = textContainer.size
        size.height = height
        textContainer.size = size
    }
}
