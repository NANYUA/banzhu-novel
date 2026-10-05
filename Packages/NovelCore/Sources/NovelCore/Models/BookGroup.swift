import Foundation
import SwiftData

/// 书架分组（D13 决策：**一级手动分组**）。
///
/// ## 设计取舍（ADR 已记录）
/// 选了「一级、每本书一个分组、用户手动指定」而不是多标签/多级：
/// 覆盖绝大多数需求，且**日后想升级到多标签/多级不需要推翻数据结构**。
///
/// ## 「全部」为什么不是一条记录
/// 「全部」= 不按 `groupId` 过滤的**隐含视图**，不占记录、不可删除、不可重命名。
/// 这是刻意设计：它不随用户误操作被删掉，也不与「未分组」混淆。
@Model
final class BookGroup {
    @Attribute(.unique) var id: UUID
    var name: String

    /// 顶部的显示顺序（越小越靠前）
    var sortIndex: Int

    var createdAt: Date

    init(name: String, sortIndex: Int = 0, createdAt: Date = Date()) {
        // ⚠️ 这里必须写 self.：本类是 SwiftData @Model，init 的形参与属性**同名**，
        // 去掉 self. 会退化成「形参赋给形参」，属性实际根本没被赋值。
        // 用内联指令豁免 SwiftFormat 的 redundantSelf 规则——这不是风格问题，是正确性问题。
        // swiftformat:disable redundantSelf
        self.id = UUID()
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        // swiftformat:enable redundantSelf
    }

    /// 用户可管理的分组（不含隐含的「全部」）
    static func userGroups(from all: [BookGroup]) -> [BookGroup] {
        all.sorted { $0.sortIndex < $1.sortIndex }
    }
}
