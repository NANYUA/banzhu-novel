import Foundation

/// 导入 txt 时用来**识别章标题**的正则规则。
///
/// ## 为什么规则是数据，不是写死的一段正则
/// 各家 txt 的目录格式千差万别（`第 1 章` / `正文 3` / `☆5` / `Chapter 12` …），
/// 一套正则不可能全中。owner 口径（2026-10-17）：内置一批可用的规则，
/// **允许用户自己增删改**，导入时按启用项依次尝试。
///
/// ## 内置规则**也可以删**
/// owner 2026-10-17：「这些正则也相当于导入的正则，只是我内置了，
/// 所以在正则的入口这些规则可以删除」⇒ `isBuiltin` 只用于界面分组与「恢复内置」，
/// **不是**「不可删除」的标记。删光后用「恢复内置」可以把缺的补回来。
public struct ImportChapterRule: Codable, Equatable, Sendable, Identifiable {
    /// 稳定标识。内置项用 `builtin-<序号>`，用户新建项用 UUID 字符串。
    ///
    /// ## 为什么是 String 而不是 UUID
    /// 内置规则要在「恢复内置」时按 id 判重（用户改过同一条就不覆盖），
    /// 用固定字符串比每次生成 UUID 更好对账。
    public var id: String

    /// 界面上显示的名字，例如「目录」「数字 分隔符 标题名称」。
    public var name: String

    /// 正则源码。使用时按「**整行**匹配」判定 —— 命中即认为该行是章标题。
    public var pattern: String

    public var isEnabled: Bool

    /// 是否来自内置表。**不影响能否删除**（见类型注释）。
    public var isBuiltin: Bool

    /// 排序号，小的先尝试。只影响界面顺序，不影响「哪条能命中」。
    public var serialNumber: Int

    public init(
        id: String,
        name: String,
        pattern: String,
        isEnabled: Bool = true,
        isBuiltin: Bool = false,
        serialNumber: Int = 0
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.isBuiltin = isBuiltin
        self.serialNumber = serialNumber
    }
}

// MARK: - 校验

public extension ImportChapterRule {
    /// 这条规则能不能用。`nil` = 可用，否则是人类可读的原因。
    ///
    /// 校验放在这里而不是界面里：导入流程也会拿到用户存的规则，
    /// 一条坏正则不能让整次导入炸掉（切章器会跳过它）。
    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "名称不能为空。"
        }
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "正则不能为空。"
        }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "正则无效：\(error.localizedDescription)"
        }
    }

    var isUsable: Bool {
        validationMessage == nil
    }

    /// 编译成可直接用于匹配的实例。坏正则返回 `nil`（调用方跳过，不中断导入）。
    internal func compiled() -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}
