import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 存储层测试。
///
/// 重点保护三条**需求硬约束**，它们一旦破掉就是用户可感知的损失：
/// 1. 用户**下载**的章节永不被缓存淘汰误删
/// 2. 缓存淘汰只针对 `cached`，且**按章节**不按书
/// 3. 阅读位置存 **characterOffset** 而非页码（改设置后不丢位置）
final class NovelStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext!

    override func setUpWithError() throws {
        // 用内存容器，不污染真实沙盒
        container = try NovelStore.makeContainer(inMemory: true)
        ctx = ModelContext(container)
    }

    override func tearDownWithError() throws {
        ctx = nil
        container = nil
    }

    // MARK: - ① 章节来源：最关键的契约

    func testChapterSource_只有缓存可被淘汰() {
        XCTAssertTrue(ChapterSource.cached.isEvictable)
        XCTAssertFalse(ChapterSource.downloaded.isEvictable,
                       "🔴 用户下载的章节绝不能被淘汰")
        XCTAssertFalse(ChapterSource.notDownloaded.isEvictable)
    }

    func testChapterRecord_来源切换会清掉文件名() {
        let ch = ChapterRecord(bookPath: "/49/1/", number: 5, name: "第五章", path: "/49/1/5.html")
        ch.source = .downloaded
        ch.localFileName = "5.txt"
        ch.savedAt = Date()
        XCTAssertTrue(ch.hasLocalText)

        // 退回「未下载」时应连带清掉本地文件索引，否则会指向一个不存在的文件
        ch.source = .notDownloaded
        XCTAssertFalse(ch.hasLocalText)
        XCTAssertNil(ch.savedAt)
    }

    /// 🔴 核心场景：一本书里「下载的章」与「缓存的章」共存
    func test同书两类章节共存_按章淘汰不误伤下载() throws {
        let bookPath = "/49/49034/"
        let downloaded = ChapterRecord(
            bookPath: bookPath, number: 1, name: "第一章", path: "/p/1.html",
            source: .downloaded, localFileName: "1.txt"
        )
        let cached = ChapterRecord(
            bookPath: bookPath, number: 51, name: "第五十一章", path: "/p/51.html",
            source: .cached, localFileName: "51.txt"
        )
        ctx.insert(downloaded)
        ctx.insert(cached)
        try ctx.save()

        // LRU 淘汰只会选中可淘汰的那一个
        let evictable = [downloaded, cached].filter(\.source.isEvictable)
        XCTAssertEqual(evictable.count, 1)
        XCTAssertEqual(evictable.first?.number, 51,
                       "🔴 淘汰目标错了：必须是缓存章，不能是下载章")
    }

    // MARK: - ② 正文文件与元数据分离

    func test正文读写往返() throws {
        let text = "春风又绿江南岸。"
        let name = try NovelStore.saveChapterText(text, bookPath: "/49/49034/", number: 3)
        XCTAssertEqual(name, "3.txt")

        let loaded = try NovelStore.loadChapterText(bookPath: "/49/49034/", number: 3)
        XCTAssertEqual(loaded, text)
        NovelStore.deleteChapterText(bookPath: "/49/49034/", number: 3)
    }

    func test书目录名不含斜杠_避免嵌套目录() {
        let dir = NovelStore.bookDir(forBookPath: "/49/49034/").lastPathComponent
        XCTAssertFalse(dir.contains("/"), "书目录名不应含斜杠：\(dir)")
    }

    func test不同书的目录互相隔离() {
        let firstBook = NovelStore.bookDir(forBookPath: "/49/1/")
        let secondBook = NovelStore.bookDir(forBookPath: "/50/2/")
        XCTAssertNotEqual(firstBook, secondBook)
    }

    func test删除不存在的文件不崩溃() {
        // 清理逻辑会遍历并删除，不能因为文件已不在就崩
        XCTAssertNoThrow(NovelStore.deleteChapterText(bookPath: "/不存在/", number: 999))
    }

    // MARK: - ③ 阅读位置：存 offset 不存页码

    func test阅读位置存字符偏移() {
        let book = BookRecord(bookPath: "/49/1/", title: "测试书")
        book.lastReadChapterPath = "/49/1/7.html"
        book.lastReadChapterName = "第七章"
        book.lastReadOffset = 8234
        XCTAssertEqual(book.lastReadOffset, 8234)
        XCTAssertEqual(book.lastReadChapterName, "第七章")
    }

    func test未读章数计算() {
        let book = BookRecord(bookPath: "/49/1/", title: "测试书")
        book.latestChapterCount = 100
        XCTAssertEqual(book.unreadCount(readChapterIndex: nil), 100, "没读过 = 全未读")
        XCTAssertEqual(book.unreadCount(readChapterIndex: 40), 60)
        XCTAssertEqual(book.unreadCount(readChapterIndex: 0), 100)
        XCTAssertEqual(book.unreadCount(readChapterIndex: 200), 0, "读到超过总章数应为 0")
    }

    // MARK: - 书架排序

    func test最近阅读排序_未读的排在最后() throws {
        let old = BookRecord(bookPath: "/1/", title: "很久没读")
        old.lastReadAt = Date(timeIntervalSince1970: 1000)
        let recent = BookRecord(bookPath: "/2/", title: "刚读过")
        recent.lastReadAt = Date(timeIntervalSince1970: 9000)
        let never = BookRecord(bookPath: "/3/", title: "没读过")
        ctx.insert(old); ctx.insert(recent); ctx.insert(never)
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<BookRecord>())
        let sorted = all.sorted {
            ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast)
        }
        XCTAssertEqual(sorted.map(\.bookPath), ["/2/", "/1/", "/3/"])
    }

    // MARK: - 下载队列

    func test下载任务_遇盾暂停不计入重试次数() {
        let task = DownloadTask(bookPath: "/1/", bookTitle: "书", chapterPath: "/1/1.html",
                                chapterName: "第一章", chapterNumber: 1)
        task.markFailed(error: "网络超时")
        XCTAssertEqual(task.attempts, 1)

        task.pauseBlocked(error: "需要人机验证")
        XCTAssertEqual(task.state, .paused)
        XCTAssertTrue(task.blockedByGuard)
        XCTAssertEqual(task.attempts, 1,
                       "🔴 遇盾是「停下」不是「重试」，attempts 不该递增")
    }

    func test下载任务_可重新入队() {
        let task = DownloadTask(bookPath: "/1/", bookTitle: "书", chapterPath: "/1/1.html",
                                chapterName: "第一章", chapterNumber: 1)
        task.markFailed(error: "超时")
        task.requeue()
        XCTAssertEqual(task.state, .queued)
        XCTAssertNil(task.lastError)
    }

    func test下载任务_完成后不可再占用队列() {
        let task = DownloadTask(bookPath: "/1/", bookTitle: "书", chapterPath: "/1/1.html",
                                chapterName: "第一章", chapterNumber: 1)
        task.markDone()
        XCTAssertTrue(task.state.isFinished)
        XCTAssertFalse(task.state.isActive)
    }

    // MARK: - 分组

    func test分组按排序字段返回() {
        let fantasy = BookGroup(name: "玄幻", sortIndex: 0)
        let romance = BookGroup(name: "言情", sortIndex: 1)
        XCTAssertEqual(BookGroup.userGroups(from: [romance, fantasy]).map(\.name), ["玄幻", "言情"])
    }

    func test书可属于分组或未分组() {
        let book = BookRecord(bookPath: "/1/", title: "测试书")
        XCTAssertNil(book.groupId, "新建的书默认未分组")
        let gid = UUID()
        book.groupId = gid
        XCTAssertEqual(book.groupId, gid)
    }
}
