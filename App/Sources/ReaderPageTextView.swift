import NovelCore
import NovelPagination
import SwiftUI
import UIKit

/// 单页 / 整章 `UITextView` 包装（UIKit 承载，SwiftUI 里用 `UIViewRepresentable`）。
///
/// 分页模式下只渲染当前页并关闭滚动；滚动模式下渲染整章并监听滚动位置。
struct PageTextView: UIViewRepresentable {
    let text: String
    let offset: Int
    let configuration: PaginationConfiguration
    let onOffsetChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainer.lineFragmentPadding = 0
        // 文本容器宽 = frame.width − textContainerInset 左右：显式钉住，不吃 UIKit 默认值。
        textView.textContainer.widthTracksTextView = true
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self

        let contentChanged = context.coordinator.appliedText != text
            || context.coordinator.appliedConfiguration != configuration
        guard contentChanged else { return }

        context.coordinator.appliedText = text
        context.coordinator.appliedConfiguration = configuration

        uiView.isScrollEnabled = configuration.pageTurnMode == .scroll
        uiView.textContainer.lineFragmentPadding = 0
        // 上面切换了 `isScrollEnabled`（UITextView 会因此重配文本容器），此处重新钉一次宽度不变量。
        // 高度**不钉**：容器高由 UITextView 自己维护——滚动模式靠它把整章排完（contentSize 完整），
        // 分页模式靠它排完本页；手动设定会与滚动开关的切换交互，属未验证改动。
        uiView.textContainer.widthTracksTextView = true
        uiView.textContainerInset = UIEdgeInsets(
            top: configuration.inset.top,
            left: configuration.inset.leading,
            bottom: configuration.inset.bottom,
            right: configuration.inset.trailing
        )
        uiView.backgroundColor = configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor
        )
        uiView.attributedText = makeAttributedString()

        if configuration.pageTurnMode == .scroll {
            context.coordinator.scrollToOffset(offset, in: uiView)
        }
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
            custom: configuration.customBackgroundColor
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PageTextView
        var appliedText: String?
        var appliedConfiguration: PaginationConfiguration?

        init(parent: PageTextView) {
            self.parent = parent
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            reportOffset(scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportOffset(scrollView)
        }

        func scrollToOffset(_ offset: Int, in textView: UITextView) {
            let location = utf16Offset(for: offset, in: textView.text)
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }

        private func reportOffset(_ scrollView: UIScrollView) {
            guard parent.configuration.pageTurnMode == .scroll,
                  let textView = scrollView as? UITextView
            else {
                return
            }

            let visibleTop = CGPoint(
                x: textView.textContainerInset.left + textView.textContainer.lineFragmentPadding,
                y: scrollView.contentOffset.y + textView.textContainerInset.top
            )
            let utf16Offset = textView.layoutManager.characterIndex(
                for: visibleTop,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            parent.onOffsetChange(characterOffset(fromUTF16: utf16Offset, in: textView.text))
        }

        private func characterOffset(fromUTF16 offset: Int, in text: String) -> Int {
            guard let utf16Index = text.utf16.index(
                text.utf16.startIndex,
                offsetBy: offset,
                limitedBy: text.utf16.endIndex
            ),
                let index = String.Index(utf16Index, within: text)
            else {
                return 0
            }
            return text.distance(from: text.startIndex, to: index)
        }

        private func utf16Offset(for characterOffset: Int, in text: String) -> Int {
            let clamped = min(max(characterOffset, 0), text.count)
            guard let index = text.index(text.startIndex, offsetBy: clamped, limitedBy: text.endIndex),
                  let utf16Index = index.samePosition(in: text.utf16)
            else {
                return text.utf16.count
            }
            return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
        }
    }
}
