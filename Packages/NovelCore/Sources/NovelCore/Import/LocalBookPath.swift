import Foundation

/// 本地（导入）txt 书的路径约定。
///
/// ## 为什么要给导入书编一个 `bookPath`
/// 存储层与阅读链路都以 `bookPath` 为唯一键，而且正文文件名完全由 `bookPath + 章号` 派生
/// （`NovelStore.bookDir(forBookPath:)` / `chapterFileName(number:)`）。只要给导入书编一个
/// **与站点路径不可能撞车**的 bookPath，就能零 schema 迁移复用整条链路：
/// ```
/// local/<hash16>/                 ← BookRecord.bookPath
/// local/<hash16>/<n>              ← ChapterRecord.path
/// Content/local_<hash16>/<n>.txt  ← 正文（由 bookDir 的「/ → _」派生，见 NovelStore.swift:47-52）
/// ```
///
/// ## 为什么用文件内容哈希
/// 同一份 txt 重复导入会得到同一个 bookPath ⇒ 「已经在书架里了」的查重**天然生效**，
/// 不需要额外的「导入记录表」，也不会出现两本一模一样却分不清来源的书。
///
/// ## 🔴 「是不是本地书」只认这一个前缀
/// 不要用「有没有 writer」「host 是否为空」「cover 是否为空」之类的间接判据 ——
/// 站点书也可能缺封面、缺作者。前缀是唯一的、无法被远端数据伪造的判据。
public enum LocalBookPath {
    /// 本地书的 bookPath 前缀。**带尾斜杠**，与站点路径（以 `/` 开头的纯数字目录）不重叠。
    public static let prefix = "local/"

    /// 由内容哈希拼 bookPath。`hash` 建议传 SHA256 的前 16 位十六进制。
    public static func bookPath(hash: String) -> String {
        "\(prefix)\(hash)/"
    }

    /// 本地书的章节路径。
    ///
    /// 为什么不直接复用 `Chapter.path` 的站点格式：`ChapterRecord.path` 是
    /// 「相对路径」语义（站点书形如 `/49/49034/`），本地章没有远端可访问性；
    /// 用 `local/<hash>/<n>` 既能一眼看出是本地章，也不会被任何「拼 URL」的代码误当成站点路径。
    public static func chapterPath(bookPath: String, number: Int) -> String {
        "\(bookPath)\(number)"
    }

    public static func isLocal(_ bookPath: String) -> Bool {
        bookPath.hasPrefix(prefix)
    }
}
