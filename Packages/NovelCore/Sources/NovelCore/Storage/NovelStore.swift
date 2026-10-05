import Foundation
import SwiftData

/// 存储层入口：持有 `ModelContainer`，并统一管理**正文文件**的落盘位置。
///
/// ## 🔴 D3 ADR 定的分工，本类就是它的落地
/// ```
/// App 沙盒/
/// ├── 数据库（SwiftData）    ← 书架、章节清单、下载/缓存标记、进度、分组
/// └── Content/<bookKey>/<n>.txt  ← 章节正文本体
/// ```
///
/// **为什么正文不入库**：一本 2000 章的书正文约 10MB，几十本就是几百 MB。
/// 全塞进数据库会让查询、迁移、备份、内存全部变慢。
/// 只把**文件名**入库、正文存文件，数据库体积就与下载量无关。
public enum NovelStore {
    /// 数据库 schema —— **新增模型必须登记在这里，漏了会编译报错**
    static let schema = Schema([
        BookRecord.self,
        ChapterRecord.self,
        BookGroup.self,
        DownloadTask.self,
    ])

    /// 生产容器（落盘）
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 正文文件位置

    /// 正文目录名。放 App 沙盒 `Application Support/` 下而非 Documents——
    /// Documents 是用户可见的文件区，正文属内部数据，不该出现在那里。
    static let contentDirName = "Content"

    /// 某本书的正文目录：`Content/<bookKey>/`
    ///
    /// `bookKey` 由 `bookPath` 派生（`/49/49034/` → `49_49034`），
    /// 去掉斜杠以免形成嵌套目录。
    static func bookDir(forBookPath bookPath: String) -> URL {
        let key = bookPath
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return contentRoot.appendingPathComponent(key.isEmpty ? "root" : key, isDirectory: true)
    }

    /// 某章正文文件名：`<章号>.txt`
    static func chapterFileName(number: Int) -> String {
        "\(number).txt"
    }

    /// 某章正文的完整路径
    static func chapterFile(bookPath: String, number: Int) -> URL {
        bookDir(forBookPath: bookPath)
            .appendingPathComponent(chapterFileName(number: number))
    }

    /// 正文根目录
    static var contentRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(contentDirName, isDirectory: true)
    }

    /// 写入一章正文。返回落盘文件名，供 `ChapterRecord.localFileName` 记录。
    @discardableResult
    static func saveChapterText(_ text: String, bookPath: String, number: Int) throws -> String {
        let url = chapterFile(bookPath: bookPath, number: number)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.lastPathComponent
    }

    /// 读取一章正文。
    /// 路径由 `bookPath + number` 推导（与 `chapterFile` 一致），不需要额外传文件名——
    /// `ChapterRecord.localFileName` 只用于排查与清理，不作为读取依据。
    static func loadChapterText(bookPath: String, number: Int) throws -> String {
        let url = chapterFile(bookPath: bookPath, number: number)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 🔴 删除一章正文。**调用前必须已确认 `ChapterSource.isEvictable`**——
    /// 误删用户下载的章节是本项目最严重的潜在事故（docs/03 §1.3）。
    static func deleteChapterText(bookPath: String, number: Int) {
        try? FileManager.default.removeItem(at: chapterFile(bookPath: bookPath, number: number))
    }
}
