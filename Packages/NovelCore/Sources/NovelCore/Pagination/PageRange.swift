import Foundation

/// 一页在全文里的字符范围（UTF-16 单位）。
///
/// 🔴 对应两条数据契约里的「阅读位置存 **characterOffset** 不存页码」：
/// 页码会因 14 项设置变化而变，但 `location`（字符偏移）在改设置后
/// 依然能唯一定位到同一处文字。`PageRange.location` 就是那个 offset。
///
/// ## 可见性
/// `public`：NovelPagination 包（TextKitMeasuring）要返回这种范围，
/// 且 App 层阅读器要读它定位，必须跨包可见。
public struct PageRange: Equatable, Sendable {
    /// 本页在全文中的起始字符偏移
    public let location: Int

    /// 本页字符数
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}
