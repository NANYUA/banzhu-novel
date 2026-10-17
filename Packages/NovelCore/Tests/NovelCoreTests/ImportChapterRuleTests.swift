import Foundation
@testable import NovelCore
import XCTest

/// 「导入目录正则」的数据层测试：内置表完整性、校验口径、恢复内置。
final class ImportChapterRuleTests: XCTestCase {
    // MARK: - 内置表

    func test内置规则_共19条且id唯一() {
        XCTAssertEqual(BuiltinImportRules.all.count, 19)
        XCTAssertEqual(Set(BuiltinImportRules.all.map(\.id)).count, 19)
        XCTAssertTrue(BuiltinImportRules.all.allSatisfy(\.isBuiltin))
        XCTAssertEqual(BuiltinImportRules.all.map(\.serialNumber), Array(0 ..< 19))
    }

    func test内置规则_正则全部能编译() {
        for rule in BuiltinImportRules.all {
            XCTAssertNil(rule.validationMessage, "内置规则 \(rule.id)（\(rule.name)）的正则应能编译")
        }
    }

    /// owner 给的那份 JSON 里启用 10 条（`-1`/`-2`/`-7`/`-8`/`-9`/`-10`/`-12`/`-14`/`-15`/`-19`）。
    /// 落库时**逐条照抄**了 `enable` 字段，这里把它钉住：以后有人批量改启用状态会立刻红。
    func test内置规则_默认启用10条() {
        XCTAssertEqual(BuiltinImportRules.all.filter(\.isEnabled).count, 10)
    }

    func test内置规则_没有一条是可淘汰或已下载这类业务字段() {
        // 规则只描述「怎么认标题」，不该携带任何章节来源语义（护住契约 ①）。
        let json = try? JSONEncoder().encode(BuiltinImportRules.all)
        let text = json.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(text.contains("downloaded"))
        XCTAssertFalse(text.contains("cached"))
    }

    // MARK: - 校验

    func test校验_空名称() {
        let rule = ImportChapterRule(id: "x", name: "  ", pattern: "第.*章")
        XCTAssertEqual(rule.validationMessage, "名称不能为空。")
        XCTAssertFalse(rule.isUsable)
    }

    func test校验_空正则() {
        let rule = ImportChapterRule(id: "x", name: "我的规则", pattern: " ")
        XCTAssertEqual(rule.validationMessage, "正则不能为空。")
    }

    func test校验_坏正则给出原因而不是崩溃() {
        let rule = ImportChapterRule(id: "x", name: "坏正则", pattern: "第(章")
        let message = rule.validationMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.hasPrefix("正则无效") == true, "实际：\(message ?? "nil")")
        XCTAssertNil(rule.compiled())
    }

    func test校验_好正则可编译() {
        let rule = ImportChapterRule(id: "x", name: "好正则", pattern: "^第[0-9]+章")
        XCTAssertNil(rule.validationMessage)
        XCTAssertNotNil(rule.compiled())
    }

    // MARK: - 恢复内置

    func test恢复内置_只补回缺的() {
        var rules = BuiltinImportRules.all
        rules.removeAll { $0.id == "builtin-5" }
        XCTAssertEqual(rules.count, 18)

        let restored = BuiltinImportRules.restoringMissingBuiltins(into: rules)
        XCTAssertEqual(restored.count, 19)
        XCTAssertTrue(restored.contains { $0.id == "builtin-5" })
    }

    /// 🔴 不覆盖用户改过的：同 id 已存在时原样保留（即使被停用了）。
    func test恢复内置_不覆盖已停用的同id规则() {
        var rules = BuiltinImportRules.all
        rules.removeAll { $0.id == "builtin-5" }
        guard let index = rules.firstIndex(where: { $0.id == "builtin-1" }) else {
            return XCTFail("内置表里应有 builtin-1")
        }
        rules[index].isEnabled = false

        let restored = BuiltinImportRules.restoringMissingBuiltins(into: rules)
        let first = restored.first { $0.id == "builtin-1" }
        XCTAssertEqual(first?.isEnabled, false, "被用户停用过的规则不该被恢复动作重新打开")
    }

    func test恢复内置_一条不缺时原样返回() {
        let rules = BuiltinImportRules.all
        XCTAssertEqual(BuiltinImportRules.restoringMissingBuiltins(into: rules).count, rules.count)
    }
}
