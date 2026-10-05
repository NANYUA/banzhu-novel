import Foundation

// ⚠️ 本文件从旧项目 `ios/Sources/Models/Models.swift` 原样迁移而来（37 行，纯数据模型）。
//
// 【为什么放在 NovelEngine 里】
// 冻结时发现：Engine 的 884 行引用了 `Book` / `Chapter` / `ExploreCategory`，
// 但这三个类型定义在 Models.swift，**没有进包 → 包无法独立编译**。
// 而 D1 已定依赖方向为 `App → NovelCore → NovelEngine`，
// 被 NovelEngine 引用的类型必须位于 NovelEngine 之内或更下层 → 只能放进本包。
//
// 【与旧项目的唯一差异】
// 全部加了 `public`。旧项目所有代码在同一 target，`internal` 就够；
// 拆成 SPM 包后跨包访问必须是 `public`，否则外面的包看不到这些类型。

/// 书籍（搜索结果 / 书架项）
public struct Book: Identifiable, Codable, Hashable {
    public var id: String { path }          // 相对路径 /区/书号/ 作唯一键
    public var path: String                 // 如 /49/49034/
    public var title: String
    public var author: String = ""
    public var intro: String = ""
    public var lastChapter: String = ""
    public var wordCount: String = ""          // 字数，如 "175万字"
    public var coverUrl: String = ""

    // ⚠️ 以下三项是**阅读进度**，由 Core 层产生而非引擎产生。
    // 严格说应该拆成 `EngineBook` 与本地存储模型两部分，此处暂沿用旧结构，
    // 待存储层设计时（T2 后续）再拆。

    /// 书架用：阅读进度
    public var lastReadChapterPath: String? = nil
    public var lastReadChapterName: String? = nil
    public var lastReadOffset: Double = 0   // ⚠️ 旧实现是滚动比例 0...1；
                                           // 新方案改为存 characterOffset（D15 决策），需改造
    public var addedAt: Date = Date()

    public init(path: String, title: String) {
        self.path = path
        self.title = title
    }
}

/// 章节
public struct Chapter: Identifiable, Codable, Hashable {
    public var id: String { path }
    public var number: Int
    public var name: String
    public var path: String                 // 如 /49/49034/123.html

    public init(number: Int, name: String, path: String) {
        self.number = number
        self.name = name
        self.path = path
    }
}

/// 书城分类入口
public struct ExploreCategory: Identifiable, Hashable {
    public var id: String { title }
    public var title: String
    public var urlTemplate: String          // 含 {{page}}
    public func url(page: Int) -> String {
        urlTemplate.replacingOccurrences(of: "{{page}}", with: String(page))
    }

    public init(title: String, urlTemplate: String) {
        self.title = title
        self.urlTemplate = urlTemplate
    }
}
