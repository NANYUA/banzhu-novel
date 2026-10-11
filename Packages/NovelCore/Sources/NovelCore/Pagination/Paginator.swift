import Foundation

/// 分页器 —— 把一章文字切成多页。
///
/// ## 核心职责
/// 只依赖 `TextMeasuring` 协议，不碰任何 UIKit。算法本身体现在这：
/// 反复「从当前位置度量一页能放多少字符 → 推进 → 下一页」，直到文字耗尽。
///
/// ## 守恒律（测试必须守住）
/// 1. `sum(pages.length) == text.count` —— 每个字符恰好落在某一页，不丢不重
/// 2. `pages[i].location == pages[i-1].location + pages[i-1].length` —— 页首尾相接，连续
/// 3. 空章节 → 返回 `[]`
/// 4. **每一页都不得以换行开头** —— 页边界正好落在换行之前时，把这些换行收回**上一页**
///    （游标越过整段连续换行，下一页从第一个非换行字符开始）
///
/// ### 第 4 条为什么必要
/// 换行与段距（`NSParagraphStyle.paragraphSpacing`）都**不占字符**。页边界若停在
/// 上一段最后一行刚好排满一页的位置，换行就被推到下一页 ⇒ 下一页首行先是空行
/// （外加一段段距）⇒ **各页正文首行在屏幕上的纵向位置不一致**；
/// 章尾多余的 `\n` 还会单独撑出一个**整页空白**的末页。
/// 把换行并到上一页末尾，渲染上不可见（不改变上一页的可见内容），守恒律 ①② 依然成立。
///
/// 只吞**换行**（`Character.isNewline`，即 `\n` / `\r` 等），**不吞空格**：
/// 行首空白由上游归一化（`ParagraphIndentStripper`，见 `ReaderFeature.State.displayText`），这里只管换行 —— 吞空格就成了第二套缩进口径。
///
/// ### 已知限制
/// 若整段文本的**第一个**字符就是换行，第一页无法把开头的换行「并给上一页」
/// （没有上一页，而丢字符会破守恒律 ①）⇒ 该页首字符仍是换行。生产里
/// `ReaderFeature.State.displayText` 以章节标题开头，不会出现这种文本。
///
/// ## 防死循环
/// 度量返回 0 时（一页连一个字符都放不下，比如容器宽度为 0），
/// 若不加保护会 `from` 永不前进 → 死循环。此时强制本页 `length = 1`，
/// 让至少能推进一个字符。
///
/// ## 可见性
/// `public`：`ReaderFeature`（NovelCore）和 App 层阅读器要用它分页，必须跨包可见。
public struct Paginator: Sendable {
    private let measurer: any TextMeasuring

    public init(measurer: any TextMeasuring) {
        self.measurer = measurer
    }

    /// 把 `text` 按 `configuration` 切成页。
    ///
    /// - Returns: 有序的 `[PageRange]`。空文本返回空数组。
    public func paginate(text: String, configuration: PaginationConfiguration) -> [PageRange] {
        let chars = Array(text)
        let count = chars.count
        guard count > 0 else { return [] }

        var pages: [PageRange] = []
        var cursor = 0

        while cursor < count {
            let measured = measurer.measurePageLength(
                text: text,
                from: cursor,
                configuration: configuration
            )

            // 防死循环：一页连一个字符都放不下时，强制放 1 个
            let pageLength = measured > 0 ? measured : 1

            // 别越过文本末尾
            let clamped = min(pageLength, count - cursor)

            // 守恒律 ④：把紧随其后的连续换行并入本页（游标推到第一个非换行字符），
            // 下一页因此必定以文字开头。被并入的换行落在本页末尾，渲染上不可见。
            var end = cursor + clamped
            while end < count, chars[end].isNewline {
                end += 1
            }

            pages.append(PageRange(location: cursor, length: end - cursor))
            cursor = end
        }

        return pages
    }
}
