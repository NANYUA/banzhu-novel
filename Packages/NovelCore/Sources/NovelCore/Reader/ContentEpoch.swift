import Foundation

/// 正文世代（content epoch）：**本 App 当前安装首次访问时的时间点**。
///
/// ## 为什么需要它
/// 旧构建把**不完整**的正文写进了本地，而落盘逻辑原先「文件已存在就不覆盖」
/// 让这份坏正文永久留存 ⇒ 分段拼接的修复在真机上永远不生效。
/// 因此：任何 `savedAt` 早于本世代的本地正文，都视为「可能是旧构建写的」，
/// 联网时应重新拉取确认（见 `ReaderLoaderLive.loadWithHeal`）。
///
/// ## 惰性写入
/// 第一次读取时若不存在，就写入 `Date()` 并返回它。
/// 阅读流程里 loader 先于缓存写入执行 ⇒ 同一轮里被缓存的新正文 `savedAt` 一定
/// **晚于** epoch，会被正确判为「新鲜」（判定用严格小于，相等也算新鲜）。
enum ContentEpoch {
    /// `UserDefaults` key，沿用本项目「`<域>.<用途>.v<版本>`」的既有命名习惯。
    static let storageKey = "reader.contentEpoch.v1"

    /// 当前安装的正文世代；首次调用时惰性写入。
    static func current(defaults: UserDefaults = .standard) -> Date {
        if let existing = defaults.object(forKey: storageKey) as? Date {
            return existing
        }
        let now = Date()
        defaults.set(now, forKey: storageKey)
        return now
    }

    /// `savedAt` 是否早于本世代（早于即「可能是旧构建写的」，需要重新拉取确认）。
    static func isStale(savedAt: Date?, epoch: Date) -> Bool {
        (savedAt ?? .distantPast) < epoch
    }
}
