import Foundation
import NovelCore
import UIKit

/// 用 Apple 排版引擎实现 `TextMeasuring`（真实度量，`import UIKit`）。
///
/// ## 为什么放独立包
/// 本文件依赖 UIKit（`NSTextStorage`/`NSLayoutManager`/`NSTextContainer`），
/// 在 macOS host 的 `swift test` 上编译不过（UIKit 在 macOS 是 AppKit）。
/// 而 `Paginator` 只依赖 `TextMeasuring` 协议，协议在纯 Swift 的 NovelCore 里，
/// 由 CI 全覆盖。这里实现协议，不强测。
///
/// ## 实现思路
/// `measurePageLength(text:from:configuration:)` 回答「从 `from` 起一页能放多少字符」：
/// 1. 取 `text[from...]`（剩余全部文字）
/// 2. 按 configuration 构建带样式的 attributed string（字号/行距/内边距）
/// 3. 建一个尺寸 = configuration.containerSize 的 `NSTextContainer`
/// 4. `NSLayoutManager` 排版后，`glyphRange(for:)` 得到本页能装下的范围
/// 5. 把该范围的 **UTF-16 长度**换算成 **Character 个数**后返回
///    （与 `PageRange.length`、`Paginator` 游标的单位一致；见 H1 与 `TextCursor`）
public struct TextKitMeasuring: TextMeasuring {
    public init() {}

    public func measurePageLength(
        text: String,
        from: Int,
        configuration: PaginationConfiguration
    ) -> Int {
        let chars = Array(text)
        guard from >= 0, from < chars.count else { return 0 }

        // 取 from 之后的全部字符（UTF-16）
        let tail = String(chars[from...])

        // 构建带样式的文字
        let font = ReadingFontFactory.makeFont(configuration: configuration)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: makeParagraphStyle(
                firstLineHeadIndent: configuration.firstLineHeadIndent,
                configuration: configuration
            ),
            .kern: configuration.characterSpacing,
        ]
        let attributed = NSMutableAttributedString(string: tail, attributes: attributes)

        // 页首若不是段落开头（本页从**段落中间**开始），本页第一行其实是续行，不该有首行缩进。
        // ⚠️ 与渲染侧 `App/Sources/ReaderPageTextView.swift` 是**同一条判据**（都调
        // `ParagraphBoundary`）：改一处必须改另一处，否则度量盒与渲染盒错位
        // —— 每页多塞 / 少塞正文，正文被裁（B0-2 几何契约）。
        // ⚠️ 只换掉切片**第一个段落**那一份样式；该页后续段落照旧带缩进。
        if !ParagraphBoundary.isParagraphStart(chars, at: from) {
            attributed.addAttribute(
                .paragraphStyle,
                value: makeParagraphStyle(firstLineHeadIndent: 0, configuration: configuration),
                range: NSRange(
                    location: 0,
                    length: ParagraphBoundary.firstParagraphUTF16Length(in: tail)
                )
            )
        }

        // 排版三件套
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        // 一页容器（尺寸来自 configuration，减掉左右内边距）
        //
        // 竖向**不再扣**（2026-10-11 语义变更）：`PageInset.top/bottom` 现在是
        // 「距屏幕边缘的绝对距离」，已经由 `ReaderView` 的布局 padding 从
        // `containerSize.height` 里扣掉（`readerContentSize` 与 `readerContentPaddings` 同源，
        // B0-2 契约），`PageTextView` 的竖向 `textContainerInset` 也恒为 0
        // ⇒ 这里若再扣一次，净高会少算 top + bottom ⇒ 每页多塞进正文，分页与实际渲染错位。
        let contentWidth = max(configuration.containerSize.width
            - configuration.inset.leading - configuration.inset.trailing, 0)
        let contentHeight = max(configuration.containerSize.height, 0)
        let container = NSTextContainer(size: CGSize(width: contentWidth, height: contentHeight))
        container.lineFragmentPadding = 0
        container.heightTracksTextView = false
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)

        // 全量排版后，取本容器覆盖的字符范围
        let glyphRange = layoutManager.glyphRange(for: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // H1：`charRange.length` 是 **UTF-16 码元**数，而本协议的游标是 **Character**
        // （`Paginator` 用 `Array(text)` 切分，守恒律写的是 `sum(pages.length) == text.count`）。
        // 两者在纯 CJK / ASCII 下恰好相等，含 emoji / 代理对生僻字 / 组合字符时才会错开
        // —— 不换算就会把每页多塞进若干字符。换算逻辑在 NovelCore 的 `TextCursor` 里，
        // 那边是纯 Swift，能被 CI 单测覆盖（本文件依赖 UIKit，CI 只编译不测试）。
        return TextCursor.characterCount(ofUTF16Length: charRange.length, in: tail)
    }

    /// 段落样式：`firstLineHeadIndent` 单独作参数，**其余字段与渲染侧逐值一致**
    /// （`App/Sources/ReaderPageTextView.swift` 的 `makeParagraphStyle`）——
    /// 两处必须同时改，否则度量盒与渲染盒错位。
    ///
    /// `firstLineHeadIndent` 传 `0` 就是「本行不加首行缩进」：续行不是新段落，缩进宽度本身
    /// 仍只有 `PaginationConfiguration.firstLineHeadIndent` 一个来源，这里不引入第二个宽度。
    private func makeParagraphStyle(
        firstLineHeadIndent: CGFloat,
        configuration: PaginationConfiguration
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = configuration.lineSpacing
        style.paragraphSpacing = configuration.paragraphSpacing
        style.firstLineHeadIndent = firstLineHeadIndent
        return style
    }
}
