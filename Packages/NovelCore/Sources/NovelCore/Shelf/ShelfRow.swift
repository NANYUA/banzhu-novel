import Foundation

/// 书架一行的**只读投影**。
///
/// ## 为什么不让界面直接拿 `BookRecord`
/// 1. `BookRecord` 是 SwiftData `@Model`。界面层若持有它，渲染路径就与
///    数据库对象绑死，测试与预览都得先建库；
/// 2. 列表排版（docs/03 §三）只用到 6 个字段，而 `BookRecord` 有 16 个，
///    其中 `intro`、`wordCount` 与列表无关。
///
/// ## 字段与需求逐行对应
/// 左侧封面 / 右 1 书名 / 右 2 作者 / 右 3 上次读到 / 右 4 最新章节 / 最右 未读章数。
///
/// ## 为什么带上 `lastReadChapterPath` / `lastReadOffset`（列表本身不显示它们）
/// 「书架 / 本地 / 分组单点书卡 ⇒ 直接进阅读页，落点 = 上次看过的页面」这条需求
/// 需要「上次读到哪一章、章内哪个偏移」。二者与 `lastReadChapterName` 同在
/// `BookRecord` 上、同一次读取就能拿到，放在这里可以**免掉一次额外的读库**
/// （阅读落点解析见 `ReadingTargetLoader`，它把行上的快照当作进度提示）。
///
/// ## 「最新章节」与「未读章数」为什么能离线显示
/// 二者都取自 `BookRecord` 上**持久化的目录快照**（`latestChapterName` /
/// `latestChapterCount`），不是每次联网现取 —— 这是需求确认过的取舍：
/// 离线时显示上次联网查到的值（可能过时），好过留空。
public struct ShelfRow: Equatable, Identifiable, Sendable {
    public init(
        bookPath: String,
        title: String,
        author: String,
        coverUrl: String,
        groupId: UUID? = nil,
        lastReadChapterName: String? = nil,
        lastReadChapterPath: String? = nil,
        lastReadOffset: Int = 0,
        latestChapterName: String? = nil,
        unreadCount: Int = 0,
        lastReadAt: Date? = nil
    ) {
        self.bookPath = bookPath
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.groupId = groupId
        self.lastReadChapterName = lastReadChapterName
        self.lastReadChapterPath = lastReadChapterPath
        self.lastReadOffset = lastReadOffset
        self.latestChapterName = latestChapterName
        self.unreadCount = unreadCount
        self.lastReadAt = lastReadAt
    }

    /// 复用 `bookPath` 作唯一标识。
    /// 单站点前提下它全局唯一（换镜像域名时也不变），见 `BookRecord` 注释。
    public var id: String {
        bookPath
    }

    public let bookPath: String
    public let title: String
    public let author: String
    public let coverUrl: String

    /// 所属分组；`nil` 表示未分组（「全部」是隐含视图，不占记录）。
    public var groupId: UUID?

    /// 「上次读到：第 N 章 章名」。离线也要能显示，故取的是持久化副本。
    public let lastReadChapterName: String?

    /// 上次读到的章节相对路径（如 `/49/49034/123.html`）。`nil` = 从没读过。
    ///
    /// 列表不显示它；它是「单点书卡直接进阅读页」的落点依据（见类型文档）。
    public let lastReadChapterPath: String?

    /// 🔴 上次读到的位置：**UTF-16 字符偏移，不是页码**（数据契约 ③）。
    ///
    /// 从没读过时是 `0`（`BookRecord.lastReadOffset` 的默认值），
    /// 语义与「第一章第一页」一致，故调用方不必区分。
    public let lastReadOffset: Int

    /// 「最新章节：章名」。🔴 离线时**可能过时**，需求已确认接受。
    public let latestChapterName: String?

    /// 未读章数 = 快照总章数 − 已读到的章序号
    public let unreadCount: Int

    /// 最后阅读时间。`nil` 表示从没读过（排序时沉底）
    public let lastReadAt: Date?
}

/// 书架排序规则。
///
/// 需求 docs/03 §2.1 只写了「**按最近阅读时间倒序**」，另外两条是落地时必须补的：
/// - **从没读过的书排最后**：它们 `lastReadAt == nil`，不明确处理会让排序不稳定
/// - **同一档内按加入时间倒序**：否则 SQLite 返回顺序一变，书架就跟着抖
///
/// ## 为什么在 Swift 里排，而不是交给 `FetchDescriptor.sortBy`
/// `lastReadAt` 是可选值，`sortBy` 交给 SQLite 后 NULL 排前还是排后取决于
/// 排序方向与驱动的实现细节，**没有测试能钉死它**。
/// 而在 Swift 里排，语义完全由本文件说了算，行为可预测、可测试。
/// 代价是把整个书架读进内存 —— 一本 `BookRecord` 几十字节，几百本书也就几十 KB。
///
/// ## 语义已被测试钉住
/// `NovelStoreTests.test最近阅读排序_未读的排在最后` 断言的就是「未读的排最后」。
enum ShelfOrder {
    /// `true` 表示 `lhs` 应排在 `rhs` 前面。
    static func isBefore(_ lhs: BookRecord, _ rhs: BookRecord) -> Bool {
        let left = lhs.lastReadAt ?? .distantPast
        let right = rhs.lastReadAt ?? .distantPast
        if left != right {
            return left > right
        }
        return lhs.addedAt > rhs.addedAt
    }
}
