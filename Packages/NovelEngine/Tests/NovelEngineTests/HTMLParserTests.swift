@testable import NovelEngine
import XCTest

/// HTML 解析测试（D11）。
///
/// fixture 的结构**严格照着 parseBookList / parseBookInfo / parseChapters
/// 里的正则构造**——这样测试才有意义：
/// 若网站改版改了 class 名或 href 格式，正则会失效、fixture 不再匹配、**测试立刻报警**。
///
/// ⚠️ 这些是「合成样本」而非线上抓的真实页面（建项目时没有留存样本）。
/// 🔴 待补：从真机抓一份真实 HTML 存进 Fixtures/，做**快照测试**，那才是最强的防改版手段。
final class HTMLParserTests: XCTestCase {
    // MARK: - parseBookList

    /// 照 class="column-2" + class="name" + href="/数字/数字/" 的结构构造
    private let bookListHTML = """
    <ul class="list">
      <li class="column-2">
        <a class="name" href="/49/49034/">楚香君游戏</a>
        <a class="author" href="/author/1/">测试作者甲</a>
        <span class="words">字数：125万字</span>
        <p>最新章节：<a href="/49/49034/999.html">第999章 大结局</a></p>
      </li>
      <li class="column-2">
        <a class="name" href="/50/50012/">重生之都市修仙</a>
        <a class="author" href="/author/2/">测试作者乙</a>
        <span class="words">字数：62万字</span>
      </li>
    </ul>
    """

    func testParseBookList_解析出两本书() {
        let books = HTMLParser.parseBookList(bookListHTML)
        XCTAssertEqual(books.count, 2, "应解析出 2 本，实际 \(books.count)")
    }

    func testParseBookList_书名与路径正确() {
        let books = HTMLParser.parseBookList(bookListHTML)
        XCTAssertEqual(books.first?.title, "楚香君游戏")
        XCTAssertEqual(books.first?.path, "/49/49034/")
    }

    func testParseBookList_作者与字数正确() {
        let books = HTMLParser.parseBookList(bookListHTML)
        XCTAssertEqual(books.first?.author, "测试作者甲")
        XCTAssertFalse(books.first?.wordCount.isEmpty ?? true, "字数未解析")
    }

    func testParseBookList_最新章节正确() {
        let books = HTMLParser.parseBookList(bookListHTML)
        XCTAssertTrue(books.first?.lastChapter.contains("大结局") ?? false,
                      "最新章节未解析，实际：\(books.first?.lastChapter ?? "nil")")
    }

    func testParseBookList_去重() {
        let dup = bookListHTML + """
        <li class="column-2">
          <a class="name" href="/49/49034/">楚香君游戏</a>
        </li>
        """
        XCTAssertEqual(HTMLParser.parseBookList(dup).count, 2, "重复书籍未被去重")
    }

    func testParseBookList_空输入返回空数组() {
        XCTAssertTrue(HTMLParser.parseBookList("").isEmpty)
        XCTAssertTrue(HTMLParser.parseBookList("<html></html>").isEmpty)
    }

    func testParseBookList_垃圾输入不崩溃() {
        // 引擎跑在用户手机上，任何输入都不能崩
        XCTAssertNoThrow(HTMLParser.parseBookList("<li class=\"column-2\"><a class=\"name\" href=\"\">空</a></li>"))
    }

    // MARK: - parseBookInfo

    /// 照 <h1> + 作者： + 字数： + class="bd" 的结构构造
    private let bookInfoHTML = """
    <div class="mod book-intro">
      <div class="cover"><img src="https://example.com/book.jpg"></div>
      <h1>楚香君游戏</h1>
      <p>作者：测试作者甲</p>
      <p>字数：125万字</p>
      <p>状态：连载中</p>
      <p>分类：玄幻</p>
      <a class="tag">热血</a>
      <a class="tag">冒险</a>
      <p>最新章节：<a href="/49/49034/9.html">第9章 新的开始</a></p>
      <p>更新时间：2026-10-09</p>
      <div class="bd">这是一本测试用的简介，用于验证解析逻辑。</div>
      <div class="bd column-2">
        <ul><li><a href="/49/49034/1.html">第1章</a></li></ul>
      </div>
    </div>
    """

    func testParseBookInfo_标题与作者() {
        let book = HTMLParser.parseBookInfo(bookInfoHTML, path: "/49/49034/")
        XCTAssertEqual(book.title, "楚香君游戏")
        XCTAssertEqual(book.path, "/49/49034/")
        XCTAssertEqual(book.author, "测试作者甲")
    }

    func testParseBookInfo_简介取第一个bd块而非章节列表() {
        // 🔴 关键回归点：页面里有多个 class="bd"，简介必须取「mod book-intro 之后」的那个，
        //    否则会把章节列表当成简介
        let book = HTMLParser.parseBookInfo(bookInfoHTML, path: "/49/49034/")
        XCTAssertTrue(book.intro.contains("测试用的简介"), "简介取错块：\(book.intro)")
        XCTAssertFalse(book.intro.contains("第1章"), "简介混入了章节列表")
    }

    func testParseBookInfo_详情字段完整解析() {
        let book = HTMLParser.parseBookInfo(bookInfoHTML, path: "/49/49034/")
        XCTAssertEqual(book.coverUrl, "https://example.com/book.jpg")
        XCTAssertEqual(book.status, "连载中")
        XCTAssertEqual(book.category, "玄幻")
        XCTAssertEqual(book.tags, ["热血", "冒险"])
        XCTAssertEqual(book.lastChapter, "第9章 新的开始")
        XCTAssertEqual(book.lastUpdated, "2026-10-09")
    }

    func testParseBookInfo_空输入不崩溃() {
        XCTAssertNoThrow(HTMLParser.parseBookInfo("", path: "/x/"))
    }

    // MARK: - parseChapters

    /// 照 href=".../数字.html" 的结构构造
    private let chaptersHTML = """
    <div class="chapter-list">
      <ul><li><a href="/49/49034/1.html">第一章 开始</a></li></ul>
      <ul><li><a href="/49/49034/2.html">第二章 继续</a></li></ul>
      <ul><li><a href="/49/49034/3.html">第三章 结束</a></li></ul>
    </div>
    """

    func testParseChapters_解析出三章() {
        let chapters = HTMLParser.parseChapters(chaptersHTML, baseURL: nil)
        XCTAssertEqual(chapters.count, 3, "应解析出 3 章，实际 \(chapters.count)")
    }

    func testParseChapters_章节名正确() {
        let chapters = HTMLParser.parseChapters(chaptersHTML, baseURL: nil)
        XCTAssertEqual(chapters.first?.name.trimmingCharacters(in: .whitespaces), "第一章 开始")
    }

    /// 🔴 契约澄清（初版我把这条写错了）：
    /// parseChapters **有意**把一切 href 归一成**相对路径**（源码注释「归一成相对路径」）。
    /// 拼绝对地址是上层 `NovelEngine.chapters()` 的活——它拿 `config.url(path:)` 拼 host。
    ///
    /// 这个设计是对的：章节路径与域名解耦，换镜像域名时**历史章节路径依然有效**。
    /// 章节数据存在本地书库里，绑死域名反而是隐患。
    func testParseChapters_归一为相对路径而非绝对地址() {
        let base = URL(string: "https://www.example.com/49/49034/")
        let chapters = HTMLParser.parseChapters(chaptersHTML, baseURL: base)
        XCTAssertEqual(chapters.first?.path, "/49/49034/1.html",
                       "传入 baseURL 时仍应存相对路径：\(chapters.first?.path ?? "nil")")
    }

    /// 绝对地址的 href 也必须被剥离成相对路径，否则书库会被域名绑死
    func testParseChapters_绝对href被剥离为相对路径() {
        let absolute = """
        <ul><li><a href="https://www.example.com/49/49034/7.html">第七章</a></li></ul>
        """
        let chapters = HTMLParser.parseChapters(absolute, baseURL: nil)
        XCTAssertEqual(chapters.first?.path, "/49/49034/7.html",
                       "绝对 href 未被归一：\(chapters.first?.path ?? "nil")")
    }

    func testParseChapters_无baseURL时保留原样() {
        let chapters = HTMLParser.parseChapters(chaptersHTML, baseURL: nil)
        XCTAssertEqual(chapters.first?.path, "/49/49034/1.html")
    }

    func testParseChapters_空输入返回空数组() {
        XCTAssertTrue(HTMLParser.parseChapters("", baseURL: nil).isEmpty)
    }

    func testParseChapters_垃圾输入不崩溃() {
        XCTAssertNoThrow(HTMLParser.parseChapters("<a href='bad'>x</a>", baseURL: nil))
    }

    // MARK: - GBK

    func testGBK_中文百分号编码() {
        // 「妻子」在 GBK 下应为 %C6%DE%D7%D3（旧项目实测值）
        let encoded = GBK.percentEncode("妻子")
        XCTAssertTrue(encoded.contains("%C6%DE"), "GBK 编码异常：\(encoded)")
    }

    func testGBK_空串安全() {
        XCTAssertEqual(GBK.percentEncode(""), "")
    }

    func testGBK_解码不崩溃() {
        XCTAssertNoThrow(GBK.decode(Data([0x81, 0x40])))
    }
}
