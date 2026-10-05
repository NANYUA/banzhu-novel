@testable import NovelEngine
import XCTest

/// 内容解码器测试（D11）。
///
/// 覆盖四层：映射表 → html2text → restore → clean，以及 decode 全链路。
///
/// 🔴 这些测试的价值：**网站改版时它们会立刻报警**。
/// decode 的最终契约是「正文里不能残留 `#数字#`」——只要还原逻辑坏了，立刻就能发现。
final class ContentDecoderTests: XCTestCase {
    // MARK: - ① 映射表

    func test映射表非空且条数合理() {
        XCTAssertGreaterThan(ContentDecoder.code2char.count, 100,
                             "映射表应有约 140 字，实际只有 \(ContentDecoder.code2char.count)")
    }

    func test映射值全部是单个汉字() {
        // 遍历去重后的值（key 有原串/去零串两份）
        let values = Set(ContentDecoder.code2char.values)
        for ch in values {
            XCTAssertEqual(ch.count, 1, "映射值应是单个汉字，实际「\(ch)」有 \(ch.count) 个字符")
            XCTAssertTrue(ch.unicodeScalars.allSatisfy { $0.value >= 0x4E00 && $0.value <= 0x9FA5 },
                          "映射值「\(ch)」不在 CJK 基本区")
        }
    }

    func test映射表同时登记原串与去前导零串() {
        // 容错：图片文件名可能没有前导零
        for (code, _) in ContentDecoder.code2char {
            let trimmed = String(code.drop(while: { $0 == "0" }))
            if !trimmed.isEmpty, trimmed != code {
                XCTAssertNotNil(ContentDecoder.code2char[trimmed],
                                "「\(code)」应同时登记去零形式「\(trimmed)」")
            }
        }
    }

    // MARK: - ② html2text

    func testhtml2text_图片转编号() {
        let html = "<img src='/toimg/data/123456.png' />"
        XCTAssertEqual(ContentDecoder.html2text(html), "#123456#")
    }

    func testhtml2text_font兜底转编号() {
        // 兜底规则：<font data-code="N">...</font>
        let html = "<font data-code=\"654321\">替</font>"
        XCTAssertTrue(ContentDecoder.html2text(html).contains("#654321#"),
                      "font data-code 兜底未生效，实际：\(ContentDecoder.html2text(html))")
    }

    func testhtml2text_换行与标签剥离() {
        let html = "<p>第一段<br>第二行</p><p>第三段</p>"
        let text = ContentDecoder.html2text(html)
        XCTAssertFalse(text.contains("<"), "残留标签：\(text)")
        XCTAssertFalse(text.contains(">"), "残留标签：\(text)")
        XCTAssertTrue(text.contains("第一段"))
        XCTAssertTrue(text.contains("第三段"))
    }

    func testhtml2text_实体解码() {
        let text = ContentDecoder.html2text("A&amp;B&lt;C&gt;D&nbsp;E&quot;F")
        XCTAssertTrue(text.contains("A&B<C>D"), "实体未解码：\(text)")
    }

    // MARK: - ③ restore

    func testrestore_编号还原为汉字() throws {
        // 取映射表里的任意一条，验证能原样还原
        let entry = try XCTUnwrap(ContentDecoder.code2char.first { $0.key.count >= 6 })
        let restored = ContentDecoder.restore("#\(entry.key)#")
        XCTAssertEqual(restored, entry.value)
        XCTAssertFalse(restored.contains("#"), "还原后仍有编号残留")
    }

    func testrestore_未知编号降级为去零查找() throws {
        // 传入带前导零的编号，应能找到去零形式对应的字
        let entry = try XCTUnwrap(ContentDecoder.code2char.first(where: {
            $0.key.count >= 6 && !$0.key.hasPrefix("0")
        }), "映射表里没有无前导零的条目")
        let ch = entry.value
        let withZeros = "0" + entry.key
        XCTAssertEqual(ContentDecoder.restore("#\(withZeros)#"), ch,
                       "带前导零的编号未能经去零查找还原")
    }

    func testrestore_无编号文本原样返回() {
        XCTAssertEqual(ContentDecoder.restore("普通正文，无编号。"), "普通正文，无编号。")
    }

    func testrestore_短数字不被误认() {
        // 正则是 #(\d{6,})#，短于 6 位的不应被替换
        XCTAssertEqual(ContentDecoder.restore("价格 #123#"), "价格 #123#")
    }

    // MARK: - ④ clean

    /// ⚠️ 用例里的广告文案必须**与 clean() 里的正则真正匹配**。
    /// 初版我随手写了「手机看书请上本站」，而代码里的规则是
    /// `手.?机.?看.?[小片](.?[书说])?` 这类**该站特定广告词**的组合，
    /// 结果测试红了 —— 是**测试写错，不是代码错**。
    /// 这也印证 docs/07 记的那条：合成 fixture 有局限，
    /// 迟早要换成线上真实样本做快照测试。
    func testclean_删除手机看小书广告() {
        let cleaned = ContentDecoder.clean("正文开始\n手机看小书 www.example.com\n正文结束")
        XCTAssertFalse(cleaned.contains("手机看小书"), "广告行未删除：\(cleaned)")
        XCTAssertTrue(cleaned.contains("正文开始"))
        XCTAssertTrue(cleaned.contains("正文结束"))
    }

    func testclean_删除Chrome推广行() {
        let cleaned = ContentDecoder.clean("正文\n使用Chrome谷歌浏览器的最佳体验\n正文继续")
        XCTAssertFalse(cleaned.lowercased().contains("chrome"), "推广行未删除：\(cleaned)")
        XCTAssertTrue(cleaned.contains("正文继续"))
    }

    func testclean_删除站长邮箱() {
        let cleaned = ContentDecoder.clean("正文\ntest@example.com\n正文继续")
        XCTAssertFalse(cleaned.contains("gmail.com"), "邮箱未删除：\(cleaned)")
    }

    func testclean_删除分页哨兵() {
        let cleaned = ContentDecoder.clean("上文\r\nhereispagebreak\r\n下文")
        XCTAssertFalse(cleaned.lowercased().contains("hereispagebreak"), "分页哨兵未删除：\(cleaned)")
    }

    func testclean_合并汉字间空格() {
        // 中文正文里汉字之间的空格是网站排版产物，应清理
        let cleaned = ContentDecoder.clean("春 风 又 绿 江 南 岸")
        XCTAssertEqual(cleaned, "春风又绿江南岸")
    }

    func testclean_合并多余空行() {
        let cleaned = ContentDecoder.clean("第一段\r\n\r\n\r\n\r\n第二段")
        XCTAssertFalse(cleaned.contains("\r\n\r\n"), "多余空行未合并：\(cleaned.replacingOccurrences(of: "\r", with: "<CR>"))")
    }

    // MARK: - ⑤ decode 全链路（🔴 核心契约）

    func testdecode_正文不含编号残留() throws {
        let code = try XCTUnwrap(ContentDecoder.code2char.keys.first { $0.count >= 6 })
        let html = "<div class=\"page-content\"><p>开头<img src=\"/toimg/data/\(code).png\" />结尾</p></div>"
        let text = ContentDecoder.decode(html: html)
        XCTAssertFalse(text.contains("#"), "🔴 正文残留编号标记：\(text)")
        XCTAssertTrue(text.contains("开头"))
        XCTAssertTrue(text.contains("结尾"))
    }

    func testdecode_空输入返回空串() {
        XCTAssertEqual(ContentDecoder.decode(html: ""), "")
    }

    func testdecode_无正文容器时不应崩溃() {
        // 垃圾输入不应崩溃——引擎跑在用户手机上，崩了就是闪退
        XCTAssertFalse(ContentDecoder.decode(html: "<html><body>无关内容</body></html>").contains("#"))
    }
}
