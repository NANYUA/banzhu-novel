import Foundation

/// 内置的章标题正则表（首次启动时的**初始数据**）。
///
/// ## 来源
/// owner 于 2026-10-17 提供的 `sharedTocRule.json`（19 条）。
/// 字段对应关系：`id` → `id`（`-1`…`-19` 改写为 `builtin-1`…`builtin-19`，
/// 避免负数 id 与用户新建的 UUID 混在一起时排序诡异）、
/// `name` → `name`、`rule` → `pattern`、`enable` → `isEnabled`、`serialNumber` → 数组下标。
///
/// ## 🔴 这些规则**不是**只读的
/// owner 明确要求「内置也可以在正则入口删除」⇒ 本表只在**没有用户数据**时作为初始值，
/// 用户删掉的规则不会自动复活；只有点「恢复内置」才把**缺的**补回来。
enum BuiltinImportRules {
    /// 一条内置规则的原始定义（不含 `isBuiltin` / `serialNumber`，由 `all` 统一补）。
    private struct Seed {
        let id: String
        let name: String
        let pattern: String
        let isEnabled: Bool

        init(_ id: String, _ name: String, _ pattern: String, enabled: Bool = true) {
            self.id = id
            self.name = name
            self.pattern = pattern
            isEnabled = enabled
        }
    }

    static let all: [ImportChapterRule] = seeds.enumerated().map { index, seed in
        ImportChapterRule(
            id: seed.id,
            name: seed.name,
            pattern: seed.pattern,
            isEnabled: seed.isEnabled,
            isBuiltin: true,
            serialNumber: index
        )
    }

    /// 「恢复内置」：把当前列表里**缺的**内置项补回来，同 id 已存在的不覆盖。
    ///
    /// 为什么按 id 而不是按正则判重：用户可能只改了一处字符，
    /// 按正则比对会把「改过的」当成「缺的」再插一条，出现两条几乎相同的规则。
    static func restoringMissingBuiltins(into current: [ImportChapterRule]) -> [ImportChapterRule] {
        let existing = Set(current.map(\.id))
        let missing = all.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return current }
        return current + missing
    }

    // swiftlint:disable line_length
    private static let seeds: [Seed] = [
        Seed(
            "builtin-1", "相对通用",
            #"第([一二两三四五六七八九十○零百千0-9１２３４５６７８９０]{1,10})[章草](.*)$"#
        ),
        Seed(
            "builtin-2", "目录",
            #"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|篇(?!张))).{0,30}$"#
        ),
        Seed(
            "builtin-3", "目录(去空白)",
            #"(?<=[　\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|篇(?!张))).{0,30}$"#,
            enabled: false
        ),
        Seed(
            "builtin-4", "目录(匹配简介)",
            #"(?<=[　\s])(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|回(?![合来事去])|场(?![和合比电是])|篇(?!张))).{0,30}$"#,
            enabled: false
        ),
        Seed(
            "builtin-5", "目录(古典、轻小说备用)",
            #"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第?\s{0,4}[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?!分)|回(?![合来事去])|场(?![和合比电是])|篇(?!张))).{0,30}$"#,
            enabled: false
        ),
        Seed(
            "builtin-6", "数字(纯数字标题)",
            #"(?<=[　\s])\d+[ 　\t]{0,4}$"#,
            enabled: false
        ),
        Seed(
            "builtin-7", "数字 分隔符 标题名称",
            #"^[ 　\t]{0,4}\d{1,5}[,.， 、_—\-].{1,30}$"#
        ),
        Seed(
            "builtin-8", "大写数字 分隔符 标题名称",
            #"^[ 　\t]{0,4}[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[ 、_—\-].{1,30}$"#
        ),
        Seed(
            "builtin-9", "正文 标题/序号",
            #"^[ 　\t]{0,4}正文[ 　]{1,4}.{0,20}$"#
        ),
        Seed(
            "builtin-10", "Chapter/Section/Part/Episode 序号 标题",
            #"^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][oO]\.|[Ee]pisode|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)\s{0,4}\d{1,4}.{0,30}$"#
        ),
        Seed(
            "builtin-11", "Chapter(去简介)",
            #"^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][Oo]\.|[Ee]pisode)\s{0,4}\d{1,4}.{0,30}$"#,
            enabled: false
        ),
        Seed(
            "builtin-12", "特殊符号 序号 标题",
            #"(?<=[\s　])[【〔〖「『〈［\[](?:第|[Cc]hapter)[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,10}[章节].{0,20}$"#
        ),
        Seed(
            "builtin-13", "特殊符号 标题(成对)",
            #"(?<=[\s　]{0,4})(?:[\[〈「『〖〔《（【\(].{1,30}[\)】）》〕〗』」〉\]]?|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$"#,
            enabled: false
        ),
        Seed(
            "builtin-14", "特殊符号 标题(单个)",
            #"(?<=[\s　]{0,4})(?:[☆★✦✧].{1,30}|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$"#
        ),
        Seed(
            "builtin-15", "章/卷 序号 标题",
            #"^[ \t　]{0,4}(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[卷章][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8})[ 　]{0,4}.{0,30}$"#
        ),
        Seed(
            "builtin-16", "顶格标题",
            #"^\S.{1,20}$"#,
            enabled: false
        ),
        Seed(
            "builtin-17", "双标题(前向)",
            #"(?m)(?<=[ \t　]{0,4})第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$(?=[\s　]{0,8}第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章)"#,
            enabled: false
        ),
        Seed(
            "builtin-18", "双标题(后向)",
            #"(?m)(?<=[ \t　]{0,4}第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$[\s　]{0,8})第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$"#,
            enabled: false
        ),
        Seed(
            "builtin-19", "标题 特殊符号 序号",
            #"^.{1,20}[(（][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[)）][ 　\t]{0,4}$"#
        ),
    ]
    // swiftlint:enable line_length
}
