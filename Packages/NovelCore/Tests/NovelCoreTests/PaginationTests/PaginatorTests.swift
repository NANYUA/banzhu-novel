import Foundation
@testable import NovelCore
import XCTest

/// 分页算法测试 —— 用 `FakeMeasuring` 确定性验证守恒律和边界。
final class PaginatorTests: XCTestCase {
    private func paginator(width: Int) -> Paginator {
        Paginator(measurer: FakeMeasuring(widthBudget: width))
    }

    /// 只暴露真正影响测试的 containerSize 宽度；字号/行距走默认值。
    private func config(width: CGFloat = 100) -> PaginationConfiguration {
        PaginationConfiguration(containerSize: CGSize(width: width, height: 300))
    }

    // MARK: - 守恒律

    /// ① 全覆盖：每个字符都落在某页
    func test每页长度之和等于全文长度() {
        let text = "Hello 你好 World 世界 emoji🙂 结束"
        let pages = paginator(width: 8).paginate(text: text, configuration: config())
        let total = pages.reduce(0) { $0 + $1.length }
        XCTAssertEqual(total, text.count, "分页后字符总数不等于原文")
    }

    /// ② 不重复：每页起始位置互不重叠
    func test页起始位置单调递增() {
        let text = "abcdefghijklmnopqrstuvwxyz0123456789"
        let pages = paginator(width: 6).paginate(text: text, configuration: config())
        for index in 1 ..< pages.count {
            XCTAssertGreaterThan(pages[index].location, pages[index - 1].location)
        }
    }

    /// ③ 不遗漏：页首尾相接，location 连续
    func test页首尾相接连续() {
        let text = "中英混合 Hello 世界 123 abc 测试"
        let pages = paginator(width: 5).paginate(text: text, configuration: config())
        for index in 1 ..< pages.count {
            XCTAssertEqual(pages[index].location, pages[index - 1].location + pages[index - 1].length)
        }
    }

    /// ④ range 连续：所有页拼起来 = 原文
    func test拼接所有页还原原文() {
        let text = "The quick brown fox jumps over the lazy dog"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        let chars = Array(text)
        let rebuilt = pages.flatMap { page in
            chars[page.location ..< (page.location + page.length)]
        }
        XCTAssertEqual(String(rebuilt), text)
    }

    // MARK: - 边界

    /// ⑤ 空章节返回空数组
    func test空章节返回空数组() {
        let pages = paginator(width: 10).paginate(text: "", configuration: config())
        XCTAssertTrue(pages.isEmpty)
    }

    /// ⑥ 超长段落（无换行）正常分页
    func test超长段落正常分页() {
        let text = String(repeating: "字", count: 1000)
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        // 中文宽 2、宽预算 10 → 每页 5 字，1000 字应分 200 页
        XCTAssertEqual(pages.count, 200)
    }

    /// ⑦ 中英混排
    func test中英混排分页() {
        let text = "Hello世界ab中文cd测试xyz"
        let pages = paginator(width: 6).paginate(text: text, configuration: config())
        // 每个 ASCII 宽 1、中文宽 2，每页容量 6
        // 会按字符逐个塞，直到超 6 为止
        let total = pages.reduce(0) { $0 + $1.length }
        XCTAssertEqual(total, text.count)
        XCTAssertGreaterThan(pages.count, 1)
    }

    /// ⑧ emoji 被当作宽字符，不拆开
    func testemoji宽字符() {
        // emoji 宽 3，宽预算 5 → 能塞 1 个 emoji（3）再塞 1 个 ASCII（1）=4，再塞一个 ASCII 超 5 停
        let text = "🙂ab"
        let pages = paginator(width: 5).paginate(text: text, configuration: config())
        let total = pages.reduce(0) { $0 + $1.length }
        XCTAssertEqual(total, 3)
    }

    // MARK: - 配置变化

    /// ⑨ 容器尺寸变化 → 分页数变化
    func test容器尺寸变化重新分页() {
        let text = String(repeating: "字", count: 100)
        let narrow = paginator(width: 10).paginate(text: text, configuration: config(width: 10))
        let wide = paginator(width: 50).paginate(text: text, configuration: config(width: 50))
        XCTAssertGreaterThan(narrow.count, wide.count, "容器窄应该页数多")
    }

    /// ⑩ 字体变化（换 fontSize）→ 分页数变化（用不同的宽预算模拟字号）
    func test字号变化重新分页() {
        let text = String(repeating: "字", count: 100)
        // 大字号 = 宽预算小 = 页数多
        let bigFont = Paginator(measurer: FakeMeasuring(widthBudget: 6))
            .paginate(text: text, configuration: config())
        let smallFont = Paginator(measurer: FakeMeasuring(widthBudget: 20))
            .paginate(text: text, configuration: config())
        XCTAssertGreaterThan(bigFont.count, smallFont.count)
    }

    /// ⑪ 防死循环：度量返回 0 时强制推进
    func test度量返回零时强制推进防死循环() {
        let text = String(repeating: "字", count: 5)
        // 宽度预算 0 → 一页都塞不进任何字符 → 强制每页 1 个
        let pages = paginator(width: 0).paginate(text: text, configuration: config())
        XCTAssertEqual(pages.count, 5, "每页强制 1 个，5 字应 5 页")
        XCTAssertEqual(pages.map(\.length), Array(repeating: 1, count: 5))
    }

    /// ⑫ 单字符文本
    func test单字符() {
        let text = "字"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].location, 0)
        XCTAssertEqual(pages[0].length, 1)
    }
}
