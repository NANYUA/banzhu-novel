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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context _: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        // 文本容器宽 = frame.width − textContainerInset 左右：显式钉住，不吃 UIKit 默认值。
        textView.textContainer.widthTracksTextView = true
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self

        let contentChanged = context.coordinator.appliedText != text
            || context.coordinator.appliedConfiguration != configuration
        guard contentChanged else { return }

        context.coordinator.appliedText = text
        context.coordinator.appliedConfiguration = configuration

        // `PageTurnMode` 只剩 `.slide`：永远是单页渲染，滚动恒关闭。
        uiView.isScrollEnabled = false
        uiView.textContainer.lineFragmentPadding = 0
        // 上面关掉了 `isScrollEnabled`（UITextView 会因此重配文本容器），此处重新钉一次宽度不变量。
        // 高度**不钉**：容器高由 UITextView 自己维护（排完本页）；手动设定属未验证改动。
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
    /// 提案未指定尺寸的场合（首次测量）用 `containerSize` 兜底，保证与度量盒同源。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView _: UITextView,
        context _: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: configuration.containerSize)
    }

    private func makeAttributedString() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = configuration.lineSpacing
        paragraphStyle.paragraphSpacing = configuration.paragraphSpacing
        paragraphStyle.firstLineHeadIndent = configuration.firstLineHeadIndent

        let backgroundColor = configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor,
            customDark: configuration.customBackgroundColorDark
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ReadingFontFactory.makeFont(configuration: configuration),
            .paragraphStyle: paragraphStyle,
            .kern: configuration.characterSpacing,
            .foregroundColor: configuration.textColorMode.uiColor(
                on: backgroundColor,
                custom: configuration.customTextColor
            ),
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    final class Coordinator: NSObject {
        var parent: PageTextView
        var appliedText: String?
        var appliedConfiguration: PaginationConfiguration?

        init(parent: PageTextView) {
            self.parent = parent
        }
    }
}
