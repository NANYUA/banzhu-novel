import Foundation
import SwiftData

/// 章节来源。
///
/// ## 🔴 这是整份需求里最容易写错、后果最严重的一处
///
/// 需求同时要求两件互相冲突的事：
/// 1. **下载**（用户主动点）→ 内容**永久保留**，直到用户自己删
/// 2. **缓存**（阅读时自动产生）→ 超过上限就淘汰最早的
///
/// 若**不区分二者**，LRU 淘汰会误删用户手动下载的章节 —— 不可接受。
///
/// 配套推论（docs/03 §1.3）：**淘汰必须按章节，不能按书**。
/// 一本书可能同时有「第 1~50 章=下载」+「第 51~80 章=缓存」，
/// 整本淘汰会连下载的 50 章一起误删。
enum ChapterSource: String, Codable, CaseIterable {
    /// 尚未保存到本地
    case notDownloaded
    /// 阅读时自动缓存的正文 → **可被 LRU 淘汰**
    case cached
    /// 用户主动下载的正文 → **永不淘汰**
    case downloaded

    /// 是否可被缓存淘汰。只有 `cached` 为 true。
    /// 🔴 凡涉及「删除本地正文」，都必须先问这一句。
    var isEvictable: Bool {
        self == .cached
    }
}

/// 章节记录（目录快照的持久化）。
///
/// ## 它同时承担三个职责
/// 1. **目录快照** —— 需求要求「离线时也能显示最新章节与未读章数」，
///    所以不能每次联网现取，必须落库
/// 2. **下载/缓存标记** —— 见 `ChapterSource`
/// 3. **正文索引** —— 只记文件名，**正文本体存文件系统**（D3 ADR）
@Model
final class ChapterRecord {
    /// 复合主键：`bookPath#number`
    @Attribute(.unique) var id: String

    /// 所属书的相对路径
    var bookPath: String

    var number: Int
    var name: String

    /// 章节相对路径，抓正文时与 host 拼接
    /// （引擎的 parseChapters 已把它**归一成相对路径**，换域名时历史数据依然有效）
    var path: String

    /// 🔴 来源标记。决定该章正文能否被缓存淘汰。
    var sourceRaw: String

    /// 正文文件名（不含路径）。正文本体在 `Content/` 目录，**不入库**。
    /// nil 表示本地没有正文。
    var localFileName: String?

    var savedAt: Date?

    init(
        bookPath: String, number: Int, name: String, path: String,
        source: ChapterSource = .notDownloaded, localFileName: String? = nil
    ) {
        // ⚠️ 这里必须写 self.：本类是 SwiftData @Model，init 的形参与属性**同名**，
        // 去掉 self. 会退化成「形参赋给形参」，属性实际根本没被赋值。
        // 用内联指令豁免 SwiftFormat 的 redundantSelf 规则——这不是风格问题，是正确性问题。
        // swiftformat:disable redundantSelf
        self.id = Self.makeId(bookPath: bookPath, number: number)
        self.bookPath = bookPath
        self.number = number
        self.name = name
        self.path = path
        self.sourceRaw = source.rawValue
        self.localFileName = localFileName
        savedAt = localFileName == nil ? nil : Date()
    }

    static func makeId(bookPath: String, number: Int) -> String {
        "\(bookPath)#\(number)"
    }

    var source: ChapterSource {
        get { ChapterSource(rawValue: sourceRaw) ?? .notDownloaded }
        set {
            self.sourceRaw = newValue.rawValue
            if newValue == .notDownloaded {
                self.localFileName = nil
                // swiftformat:enable redundantSelf
                savedAt = nil
            }
        }
    }

    /// 本地是否有正文
    var hasLocalText: Bool {
        localFileName != nil
    }
}
