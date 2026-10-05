import Foundation
import SwiftData

/// 书架条目（对应「书架」列表的一行）。
///
/// ## 为什么读进度直接放在这里而不是独立表
/// 需求里书架的核心查询是「**按最近阅读排序**并显示书名/作者/上次章节/最新章节/未读数」——
/// 这些字段总是一起出现。若把进度拆成独立表，每次列表查询都要做一次连接。
/// 单站点场景下没有跨库需求，**冗余一次读取、省掉一次 join** 是更划算的取舍。
///
/// ## 关于 `bookPath` 作为唯一键
/// 引擎的 `Chapter.path` 是**相对路径**（如 `/49/49034/`），
/// 换镜像域名时历史数据依然有效 —— 这正是 parseChapters 归一成相对路径的目的。
/// 单站点前提下它可以安全地当主键；**若将来支持多站点，需改为 (siteID, bookPath) 复合键**。
@Model
final class BookRecord {
    /// 相对书路径，如 `/49/49034/`。单站点下即全局唯一。
    @Attribute(.unique) var bookPath: String

    var title: String
    var author: String
    var intro: String
    var coverUrl: String
    var wordCount: String

    /// 所属分组（D13 决策：一级手动分组，每本书只能属于一个分组）
    /// `nil` 表示未分组。**「全部」是隐含的**（不按 groupId 过滤即为全部），不占记录。
    var groupId: UUID?

    var addedAt: Date

    // MARK: - 阅读进度

    /// 上次读到的章节相对路径
    var lastReadChapterPath: String?

    /// 上次读到的章节名（列表第 3 行要显示，离线时也得能显示）
    var lastReadChapterName: String?

    /// 🔴 阅读位置：**UTF-16 字符偏移，不是页码**
    ///
    /// D15 决策 + vreader 的 `pageContaining(offsetUTF16:)` 印证：
    /// 14 项阅读设置里字号/行距/段距/页边距/首行缩进**全都会改变分页**，
    /// 存页号会导致改设置后阅读位置错乱。改设置后重新分页，
    /// 再按 offset 反查它落在第几页即可。
    var lastReadOffset: Int = 0

    /// 最后一次阅读时间 —— **书架默认排序键**
    var lastReadAt: Date?

    // MARK: - 更新检查（用于「最新章节」栏）

    /// 上次联网检查更新是否有新章节的时间
    var lastCheckedAt: Date?

    /// 目录快照里已知的最新章节名（离线时也能显示「最新章节」栏）
    var latestChapterName: String?

    /// 目录快照里的总章节数（用于算「未读章数」）
    var latestChapterCount: Int = 0

    init(
        bookPath: String, title: String, author: String = "", intro: String = "",
        coverUrl: String = "", wordCount: String = "", addedAt: Date = Date()
    ) {
        // ⚠️ 这里必须写 self.：本类是 SwiftData @Model，init 的形参与属性**同名**，
        // 去掉 self. 会退化成「形参赋给形参」，属性实际根本没被赋值。
        // 用内联指令豁免 SwiftFormat 的 redundantSelf 规则——这不是风格问题，是正确性问题。
        // swiftformat:disable redundantSelf
        self.bookPath = bookPath
        self.title = title
        self.author = author
        self.intro = intro
        self.coverUrl = coverUrl
        self.wordCount = wordCount
        self.addedAt = addedAt
        // swiftformat:enable redundantSelf
    }

    // MARK: - 派生（列表第 3/4/5 行）

    /// 「上次读到：第 N 章 章名」
    var lastReadDisplay: String? {
        guard let name = lastReadChapterName else { return nil }
        return name
    }

    /// 「最新章节：章名」。🔴 离线时显示的是**上次联网时的已知值**，可能过时——
    /// 这是 D13 决策刻意选的行为（离线显示已知值，好过留空）。
    var latestChapterDisplay: String? {
        latestChapterName
    }

    /// 未读章数 = 目录总章数 − 已读章数。
    /// 已读章数由**阅读位置所在章之前**的章节数决定（含当前章，因为可能没读完）。
    func unreadCount(readChapterIndex: Int?) -> Int {
        guard latestChapterCount > 0 else { return 0 }
        guard let idx = readChapterIndex else { return latestChapterCount }
        return max(0, latestChapterCount - idx)
    }
}
