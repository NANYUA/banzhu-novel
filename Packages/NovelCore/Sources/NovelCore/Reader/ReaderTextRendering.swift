import Foundation

/// 未展开的页内容；范围使用 Character 偏移，与分页器一致。
/// 先比较这个值，再做正文归一化和切片，避免跟手更新重复遍历整章。
public struct ReaderPageContent: Equatable, Sendable {
    public let text: String
    public let chapterName: String
    public let page: PageRange?

    public init(text: String, chapterName: String = "", page: PageRange? = nil) {
        self.text = text
        self.chapterName = chapterName
        self.page = page
    }

    public var renderedSlice: ReaderPageSlice {
        let source = ReaderFeature.State.displayText(chapterName: chapterName, text: text)
        guard let page else { return ReaderPageSlice(text: source, startsAtParagraphStart: true) }
        let chars = Array(source)
        guard page.location >= 0, page.location < chars.count, page.length > 0 else {
            return ReaderPageSlice(text: "", startsAtParagraphStart: true)
        }
        let start = page.location
        let end = start + min(page.length, chars.count - start)
        return ReaderPageSlice(
            text: String(chars[start ..< end]),
            startsAtParagraphStart: ParagraphBoundary.isParagraphStart(chars, at: start)
        )
    }
}

public struct ReaderPageSlice: Equatable, Sendable {
    public let text: String
    public let startsAtParagraphStart: Bool
}

/// 每个文本视图仅保留一页；无关状态变化不重建切片或富文本。
public struct ReaderTextRenderCache: Sendable {
    private var content: ReaderPageContent?
    private var configuration: PaginationConfiguration?
    public private(set) var slice = ReaderPageSlice(text: "", startsAtParagraphStart: true)

    public init() {}

    /// 返回是否需要更新文本视图。仅样式变化时复用已切好的页文本及段首判据。
    public mutating func update(content: ReaderPageContent, configuration: PaginationConfiguration) -> Bool {
        let contentChanged = self.content != content
        let styleChanged = self.configuration.map { affectsRendering(configuration, comparedTo: $0) } ?? true
        self.configuration = configuration
        guard contentChanged || styleChanged else { return false }
        if contentChanged {
            slice = content.renderedSlice
            self.content = content
        }
        return true
    }

    private func affectsRendering(
        _ configuration: PaginationConfiguration,
        comparedTo previous: PaginationConfiguration
    ) -> Bool {
        // 外观由动态颜色响应 traits；控制栏、边框和亮度策略不改变正文属性。
        configuration.affectsPagination(comparedTo: previous)
            || configuration.backgroundStyle != previous.backgroundStyle
            || configuration.customBackgroundColor != previous.customBackgroundColor
            || configuration.customBackgroundColorDark != previous.customBackgroundColorDark
            || configuration.textColorMode != previous.textColorMode
            || configuration.customTextColor != previous.customTextColor
    }
}
