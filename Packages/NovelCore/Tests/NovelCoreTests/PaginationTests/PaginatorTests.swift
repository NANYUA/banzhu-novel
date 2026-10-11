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

    /// ⑫ 排版类设置变化会影响分页。
    func test排版设置影响分页() {
        let base = config()
        var typography = base
        typography.characterSpacing = 2
        XCTAssertTrue(typography.affectsPagination(comparedTo: base))

        var bold = base
        bold.isBold = true
        XCTAssertTrue(bold.affectsPagination(comparedTo: base))
    }

    /// ⑬ 外观 / 翻页类设置不影响分页。
    ///
    /// `pageTurnMode` / `pageTurnAnimation` 已收敛为单一取值（见 ⑱），无法再通过改值验证，
    /// 这里改用新增的暗色自定义背景色作为「只影响渲染」的代表字段。
    func test外观设置不影响分页() {
        let base = config()
        var appearance = base
        appearance.backgroundStyle = .black
        appearance.customBackgroundColorDark = ReadingColor(red: 0.1, green: 0.1, blue: 0.12)
        appearance.textColorMode = .custom
        appearance.followsSystemBrightness = false
        appearance.appearanceMode = .dark
        XCTAssertFalse(appearance.affectsPagination(comparedTo: base))
    }

    /// 正文边框标识**不影响分页**：开关它不许重排整章、不许动阅读位置。
    ///
    /// 锁的失效模式：把它写进 `affectsPagination` ⇒ 用户在设置里开关一次边框，
    /// 就会触发整章重排（长章明显卡一下）并按 offset 重新定位 —— 而边框只是叠加层。
    /// （编号沿用 ⑬ 的「只影响渲染」一族，不参与本文件已乱的 ⑪–⑳ 序号。）
    func test正文边框标识开关不影响分页() {
        let base = config()
        var withBorder = base
        withBorder.showsTextAreaBorder = true
        XCTAssertFalse(withBorder.affectsPagination(comparedTo: base))
        // 反向同样成立（关掉边框也不重排）。
        XCTAssertFalse(base.affectsPagination(comparedTo: withBorder))
    }

    /// ⑭ 防死循环：度量返回 0 时强制推进
    func test度量返回零时强制推进防死循环() {
        let text = String(repeating: "字", count: 5)
        // 宽度预算 0 → 一页都塞不进任何字符 → 强制每页 1 个
        let pages = paginator(width: 0).paginate(text: text, configuration: config())
        XCTAssertEqual(pages.count, 5, "每页强制 1 个，5 字应 5 页")
        XCTAssertEqual(pages.map(\.length), Array(repeating: 1, count: 5))
    }

    /// ⑮ 单字符文本
    func test单字符() {
        let text = "字"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].location, 0)
        XCTAssertEqual(pages[0].length, 1)
    }

    // MARK: - 不变量 ④：页面不得以换行开头

    /// ⑳ 页边界正好落在 `\n` 前 ⇒ 该换行并入上一页，下一页以文字开头。
    ///
    /// 修复前：第 1 页正好排满 5 个中文 ⇒ `\n` 被推到第 2 页 ⇒ 第 2 页首行是空行。
    func test页边界落在换行前时换行并入上一页() {
        let text = "一二三四五\n六七八九十"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        let chars = Array(text)

        XCTAssertEqual(pages.count, 2, "换行不另起一页")
        XCTAssertEqual(pages.map { chars[$0.location] }, ["一", "六"], "每页都必须以正文开头")
    }

    /// ㉑ 连续多个换行（`\n\n`）一并并入上一页。
    func test连续多个换行一并并入上一页() {
        let text = "一二三四五\n\n六七八九十"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        let chars = Array(text)

        // 只并一个的话，第 2 页会以第二个 `\n` 开头（页首仍是空行）。
        XCTAssertEqual(pages.count, 2, "两个换行也必须一起收走")
        XCTAssertEqual(pages.map { chars[$0.location] }, ["一", "六"], "每页都必须以正文开头")
    }

    /// ㉒ 章尾多余换行 ⇒ 不产生「整页只有换行」的末页（整页空白）。
    func test章尾多余换行不产生只有换行的末页() {
        let text = "一二三四五六七八九十\n\n"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        let chars = Array(text)

        // 修复前：第 2 页正好排满 5 个中文 ⇒ 章尾那两个 `\n` 单独撑出第 3 页。
        XCTAssertEqual(pages.count, 2, "章尾换行不另起一页")
        XCTAssertTrue(
            pages.allSatisfy { page in
                (0 ..< page.length).contains { !chars[page.location + $0].isNewline }
            },
            "每一页都必须含正文"
        )
        XCTAssertEqual(pages.map { chars[$0.location] }, ["一", "六"])
    }

    /// ㉓ 守恒律在带换行的文本上仍成立（① 不丢字符 ② 页首尾相接 ④ 不以换行开头）。
    func test带换行的文本仍守住守恒律() {
        let text = "第一章\n\n一二三四五\n\n六七八九十\n\n\n甲乙丙"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())
        let chars = Array(text)

        XCTAssertEqual(pages.reduce(0) { $0 + $1.length }, text.count, "① 每个字符恰好落在一页")
        XCTAssertEqual(pages.first?.location, 0)
        for index in 1 ..< pages.count {
            XCTAssertEqual(
                pages[index].location,
                pages[index - 1].location + pages[index - 1].length,
                "② 页首尾相接"
            )
        }
        XCTAssertTrue(pages.allSatisfy { $0.length > 0 }, "每页非空")
        XCTAssertTrue(
            pages.allSatisfy { !chars[$0.location].isNewline },
            "④ 任何一页都不得以换行开头"
        )
    }

    /// ㉔ 回归保护：**不含换行**的文本，分页结果与改动前逐值相同。
    ///
    /// 这里钉的是旧口径的逐值结果（纯按度量整块切分），防止换行合并逻辑误伤无换行文本。
    func test不含换行的文本分页逐值不变() {
        let ascii = "abcdefghijklmnopqrstuvwxyz0123456789"
        XCTAssertEqual(
            paginator(width: 6).paginate(text: ascii, configuration: config()),
            [
                PageRange(location: 0, length: 6),
                PageRange(location: 6, length: 6),
                PageRange(location: 12, length: 6),
                PageRange(location: 18, length: 6),
                PageRange(location: 24, length: 6),
                PageRange(location: 30, length: 6),
            ]
        )

        let mixed = "Hello世界ab中文cd测试xyz"
        XCTAssertEqual(
            paginator(width: 6).paginate(text: mixed, configuration: config()),
            [
                PageRange(location: 0, length: 5),
                PageRange(location: 5, length: 4),
                PageRange(location: 9, length: 4),
                PageRange(location: 13, length: 4),
                PageRange(location: 17, length: 1),
            ]
        )
    }

    /// ㉕ 防死循环那条路（度量返回 0 ⇒ 强制 1 个字符）首字符恰好是换行：
    /// 仍然每页至少推进 1 个字符，连续换行一并并入本页。
    ///
    /// 文本开头的换行属于**已知限制**（第一页没有上一页可并，见 `Paginator` 类型注释）。
    func test度量返回零且文本以换行开头时不死循环() {
        let text = "\n\n一二三"
        let pages = paginator(width: 0).paginate(text: text, configuration: config())
        let chars = Array(text)

        XCTAssertEqual(pages.reduce(0) { $0 + $1.length }, text.count, "不丢字符")
        XCTAssertEqual(pages.map { chars[$0.location] }, ["\n", "一", "二", "三"], "换行只留在文本开头那一页")
    }

    /// ㉖ 极端输入：整段全是换行 —— 不死循环、不丢字符（生产里不会出现，算法不能崩）。
    func test全是换行的文本不死循环() {
        let text = "\n\n\n"
        let pages = paginator(width: 10).paginate(text: text, configuration: config())

        XCTAssertEqual(pages.reduce(0) { $0 + $1.length }, text.count)
        XCTAssertEqual(pages.count, 1, "一页放得下的换行不该撑出多页")
    }

    // MARK: - 默认页边距（U1-8 → U9-3b → U9-7）

    /// ⑯ 默认页边距：左右 24、上下 **78 / 30**（**距屏幕边缘的绝对距离**，`0` = 贴屏幕边）。
    ///
    /// 这个默认值此前**没有任何测试锁着**（B0-4 把它从 0 改成 16 时也没锁），
    /// 改歪了没人会发现。U1-8 补了锚点（当时上下是 8）；
    /// U9-3b owner 要求「正文贴安全区、上下边距 0 起点」，锚点同步到 0；
    /// U9-7 owner 真机反馈「距离屏幕上下太远」，锚点同步到 -24 / -22；
    /// 随后 owner 说明其机型是**刘海屏**（无灵动岛），而 `-24` 只按灵动岛推导
    /// （余量 0pt，刘海屏只剩约 3pt），故上边距收到 **-18**；
    /// 又因设置面板是**一个**滑杆同时写上下（`verticalInsetBinding`），
    /// 非对称默认值会让 `bottom` 落在滑杆范围之外、一拖就被夹走，故下边距也取对称的 **-18**。
    /// 2026-10-11 owner 改口径：上下边距的**参考点从安全区换成屏幕边缘**（`0` = 贴屏幕最边缘、
    /// **不自己适配刘海**），范围上 `0…200` / 下 `0…120`，**两个滑杆各改各的**，
    /// 默认 **78 / 30** —— 旧负值在新语义下无意义，由迁移（key `v3`）重置。
    /// **这条用例的价值就在于：上下默认值每被改一次，都必须在这里显式改一次。**
    func test默认页边距左右二十四上下七十八与三十() {
        let inset = PageInset()
        XCTAssertEqual(inset.leading, 24)
        XCTAssertEqual(inset.trailing, 24)
        XCTAssertEqual(inset.top, 78)
        XCTAssertEqual(inset.bottom, 30)
    }

    /// ⑰ 分页配置与落盘设置必须**同源**取默认值：
    /// 两处都写 `PageInset()`，只要有人把其中一处改成字面量就会漂移，
    /// 表现为「从没动过设置，但读过一次设置后页边距变了」。
    func test分页配置与阅读设置的默认页边距同源() {
        XCTAssertEqual(config().inset, PageInset())
        XCTAssertEqual(ReadingSettings().inset, PageInset())
    }

    // MARK: - 阅读界面改版：翻页方式 / 动画收敛、亮暗自定义背景色

    /// ⑱ 翻页方式只剩「左右滑动」、翻页动画只剩默认（无动画）。
    ///
    /// owner 决定删除 `PageTurnMode.tap` / `.scroll` 与 `PageTurnAnimation.cover` / `.curl`。
    /// 删掉 case 之后，「翻页设置不影响分页」已无法通过改值来验证（只剩一个取值），
    /// 因此这条断言改为锁住「只保留唯一取值」这个事实：谁把 case 加回来，测试立刻红。
    func test翻页方式与翻页动画只保留唯一样式() {
        XCTAssertEqual(PageTurnMode.allCases, [.slide])
        XCTAssertEqual(PageTurnAnimation.allCases, [.none])
    }

    /// ⑲ 新增的暗色自定义背景色：默认值沿用亮色默认值，且分页配置与落盘设置同源。
    func test暗色自定义背景色默认值与两处同源() {
        XCTAssertEqual(config().customBackgroundColorDark, ReadingColor.defaultCustomBackground)
        XCTAssertEqual(ReadingSettings().customBackgroundColorDark, ReadingColor.defaultCustomBackground)
    }
}
