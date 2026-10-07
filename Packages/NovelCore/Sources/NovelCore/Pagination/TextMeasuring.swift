import Foundation

/// 文本度量协议 —— 把「分页算法」和「真实排版度量」劈开的关键。
///
/// ## 为什么需要这个协议
/// 分页算法（我的代码）是**高风险、必须测**的；真实排版度量（Apple 的
/// NSTextStorage/NSLayoutManager）是**Apple 实现、不该测**的。
/// 若两者揉在一起，算法会因依赖 UIKit 而在 macOS host 的 `swift test` 上
/// 编译不过（UIKit 在 macOS 不存在，对应 AppKit），CI 就测不到算法。
///
/// 用协议劈开后：
/// - `Paginator` 只依赖本协议 → 纯 Swift，CI 全覆盖
/// - `TextKitMeasuring`（NovelPagination 包）实现本协议 → import UIKit，
///   放独立包，不强测
///
/// ## 语义
/// 给定一段文字和一个起点，度量「从 `from` 开始能塞进一页多少个字符」。
///
/// ## 可见性
/// `public`：`TextKitMeasuring`（NovelPagination 包）要实现本协议，必须跨包可见。
public protocol TextMeasuring: Sendable {
    /// 度量从 `from` 起的 `text` 中，一页能放多少字符。
    ///
    /// - Parameters:
    ///   - text: 全文
    ///   - from: 起始字符偏移
    ///   - configuration: 分页配置（容器尺寸/字号/行距/内边距等）
    /// - Returns: 本页能容纳的字符数。**0 表示一页都放不下**（由 Paginator 防死循环）。
    func measurePageLength(
        text: String,
        from: Int,
        configuration: PaginationConfiguration
    ) -> Int
}
