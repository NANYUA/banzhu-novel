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
        textView.textContainer.lineFragmentPadding = 0
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
