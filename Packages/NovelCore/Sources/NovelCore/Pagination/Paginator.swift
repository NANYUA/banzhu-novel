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
///
/// ## 防死循环
/// 度量返回 0 时（一页连一个字符都放不下，比如容器宽度为 0），
/// 若不加保护会 `from` 永不前进 → 死循环。此时强制本页 `length = 1`，
/// 让至少能推进一个字符。
struct Paginator: Sendable {
    private let measurer: any TextMeasuring

    init(measurer: any TextMeasuring) {
        self.measurer = measurer
    }

    /// 把 `text` 按 `configuration` 切成页。
    ///
    /// - Returns: 有序的 `[PageRange]`。空文本返回空数组。
    func paginate(text: String, configuration: PaginationConfiguration) -> [PageRange] {
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

            pages.append(PageRange(location: cursor, length: clamped))
            cursor += clamped
        }

        return pages
    }
}
