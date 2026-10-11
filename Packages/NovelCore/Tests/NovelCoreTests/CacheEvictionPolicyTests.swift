import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 「已读章节 + 当前预取窗口不被淘汰」策略测试（owner 2026-10-11 口径）。
///
/// ## 背景（owner 反馈）
/// 「阅读界面的预缓存不起效果，我直接点击下一章还是需要加载」、
/// 「我想返回上一章也需要加载，似乎是直接将缓存删除了」。
/// 旧策略只按章号升序删，把用户**刚读过**与**正要读**的章节一起删了。
///
/// ## 现在的判据
/// 可淘汰集合 = `.cached` 且 `number > 已读章号 + precacheCount`
/// （已读章号取 `BookRecord.lastReadChapterPath` 指向章节的 `number`）。
/// ⇒ 在读的那本书天然全保：它的缓存要么已读、要么就在窗口内。
///
/// 上限 / 计数 / 排序 / 来源那几条在 `CacheEvictionTests.swift`。
@MainActor
final class CacheEvictionPolicyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try NovelStore.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    func test已读章节与预取窗口内章节不被淘汰() throws {
        let bookPath = "/cache/policy/reading/"
        let otherPath = "/cache/policy/reading-other/"
        let book = BookRecord(bookPath: bookPath, title: "在读")
        book.lastReadAt = Date(timeIntervalSince1970: 1000)
        let other = BookRecord(bookPath: otherPath, title: "另一本")
        other.lastReadAt = Date(timeIntervalSince1970: 9000)

        // 已读到第 5 章、预取 3 章 ⇒ 4...8 全保留；第 9 章与更早的陈旧预取 51 才可淘汰。
        let chapters = [4, 5, 6, 7, 8, 9, 51].map { cachedChapter(bookPath: bookPath, number: $0) }
        let byNumber = Dictionary(uniqueKeysWithValues: chapters.map { ($0.number, $0) })
        book.lastReadChapterPath = try XCTUnwrap(byNumber[5]).path
        let otherChapter = cachedChapter(bookPath: otherPath, number: 51)
        context.insert(book); context.insert(other)
        for chapter in chapters {
            context.insert(chapter)
        }
        context.insert(otherChapter)
        try context.save()

        let plans = try NovelStore.evictCachedChapters(
            in: context,
            maxCachedBooks: 1,
            precacheCount: 3
        )

        XCTAssertEqual(plans.map(\.bookPath), [bookPath])
        XCTAssertEqual(plans.first?.chapterIDs.count, 2)
        for number in [4, 5, 6, 7, 8] {
            XCTAssertEqual(
                try XCTUnwrap(byNumber[number]).source,
                .cached,
                "第 \(number) 章已读或在预取窗口内，不该被淘汰"
            )
        }
        XCTAssertEqual(try XCTUnwrap(byNumber[9]).source, .notDownloaded)
        XCTAssertEqual(try XCTUnwrap(byNumber[51]).source, .notDownloaded)
        XCTAssertEqual(otherChapter.source, .cached)
    }

    func test淘汰不删已读章节的正文文件() throws {
        let bookPath = "/cache/policy/files/"
        let otherPath = "/cache/policy/files-other/"
        let book = BookRecord(bookPath: bookPath, title: "在读")
        book.lastReadAt = Date(timeIntervalSince1970: 1000)
        let other = BookRecord(bookPath: otherPath, title: "另一本")
        other.lastReadAt = Date(timeIntervalSince1970: 9000)
        let read = cachedChapter(bookPath: bookPath, number: 5)
        let stale = cachedChapter(bookPath: bookPath, number: 51)
        book.lastReadChapterPath = read.path
        context.insert(book); context.insert(other)
        context.insert(read); context.insert(stale)
        context.insert(cachedChapter(bookPath: otherPath, number: 51))
        try NovelStore.saveChapterText("已读正文", bookPath: bookPath, number: 5)
        try NovelStore.saveChapterText("陈旧预取", bookPath: bookPath, number: 51)
        defer {
            NovelStore.deleteChapterText(bookPath: bookPath, number: 5)
            NovelStore.deleteChapterText(bookPath: bookPath, number: 51)
        }
        try context.save()

        _ = try NovelStore.evictCachedChapters(
            in: context,
            maxCachedBooks: 1,
            precacheCount: 3
        )

        // 「返回上一章不用重新加载」的实质：已读章节的正文文件必须还在磁盘上。
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: NovelStore.chapterFile(bookPath: bookPath, number: 5).path
            )
        )
        XCTAssertEqual(read.source, .cached)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: NovelStore.chapterFile(bookPath: bookPath, number: 51).path
            )
        )
        XCTAssertEqual(stale.source, .notDownloaded)
    }

    func test已读章节路径查不到时按未读处理() throws {
        let bookPath = "/cache/policy/dirty/"
        let otherPath = "/cache/policy/dirty-other/"
        let book = BookRecord(bookPath: bookPath, title: "脏数据")
        book.lastReadAt = Date(timeIntervalSince1970: 1000)
        // 指向章节表里不存在的路径：查不到已读章号 ⇒ 退化为 0，只有前 3 章受保护。
        book.lastReadChapterPath = "\(bookPath)gone.html"
        let other = BookRecord(bookPath: otherPath, title: "另一本")
        other.lastReadAt = Date(timeIntervalSince1970: 9000)
        let window = cachedChapter(bookPath: bookPath, number: 1)
        let stale = cachedChapter(bookPath: bookPath, number: 51)
        context.insert(book); context.insert(other)
        context.insert(window); context.insert(stale)
        context.insert(cachedChapter(bookPath: otherPath, number: 51))
        try context.save()

        let plans = try NovelStore.evictCachedChapters(
            in: context,
            maxCachedBooks: 1,
            precacheCount: 3
        )

        XCTAssertEqual(plans.map(\.bookPath), [bookPath])
        XCTAssertEqual(window.source, .cached)
        XCTAssertEqual(stale.source, .notDownloaded)
    }

    func test整本都无可淘汰章节时不产出空计划() throws {
        // 两本书都只有窗口内的缓存：宁可暂时超上限，也不删用户在读 / 待读的内容。
        let first = BookRecord(bookPath: "/cache/policy/keep-first/", title: "第一本")
        first.lastReadAt = Date(timeIntervalSince1970: 1000)
        let second = BookRecord(bookPath: "/cache/policy/keep-second/", title: "第二本")
        second.lastReadAt = Date(timeIntervalSince1970: 2000)
        let firstChapter = cachedChapter(bookPath: first.bookPath, number: 1)
        let secondChapter = cachedChapter(bookPath: second.bookPath, number: 2)
        context.insert(first); context.insert(second)
        context.insert(firstChapter); context.insert(secondChapter)
        try context.save()

        let plans = try NovelStore.evictCachedChapters(
            in: context,
            maxCachedBooks: 1,
            precacheCount: 3
        )

        XCTAssertTrue(plans.isEmpty, "没有可淘汰章节的书不该产出空计划")
        XCTAssertEqual(firstChapter.source, .cached)
        XCTAssertEqual(secondChapter.source, .cached)
    }

    /// 集成守卫：`ChapterCacheStoreLive.cache` 必须把 `followingCount` 当预缓存章数传给淘汰。
    ///
    /// 漏传会退回默认值 3 ⇒ 用户把预缓存调到 5 时，刚预取、还没读的第 54、55 章
    /// 会被自己这一轮淘汰删掉 —— 正是 owner 报的「预缓存不起效果」。
    func test自动缓存入口把预缓存章数传给淘汰() async throws {
        let bookPath = "/cache/policy/thread/"
        let book = BookRecord(bookPath: bookPath, title: "在读")
        book.lastReadAt = Date(timeIntervalSince1970: 1000)
        let readChapter = cachedChapter(bookPath: bookPath, number: 50)
        book.lastReadChapterPath = readChapter.path
        let following = (51 ... 55).map { cachedChapter(bookPath: bookPath, number: $0) }
        context.insert(book); context.insert(readChapter)
        for chapter in following {
            context.insert(chapter)
        }
        // 12 本有缓存的书 + 上限 10 ⇒ 必淘汰最冷的两本，而在读的这本就是最冷的。
        var otherChapters: [ChapterRecord] = []
        for index in 0 ..< 11 {
            let other = BookRecord(
                bookPath: "/cache/policy/thread-other-\(index)/",
                title: "第\(index)本"
            )
            other.lastReadAt = Date(timeIntervalSince1970: 2000 + Double(index))
            let chapter = cachedChapter(bookPath: other.bookPath, number: 51)
            otherChapters.append(chapter)
            context.insert(other)
            context.insert(chapter)
        }
        try context.save()
        defer { NovelStore.deleteChapterText(bookPath: bookPath, number: 50) }

        await ChapterCacheStoreLive.cache(
            chapterPath: readChapter.path,
            currentText: "第50章正文",
            followingCount: 5,
            in: context
        ) { path in
            XCTFail("51...55 已有本地正文，不该再请求 \(path)")
            return ""
        }

        for chapter in following {
            XCTAssertEqual(
                chapter.source,
                .cached,
                "刚预取、还没读的第 \(chapter.number) 章不该被淘汰"
            )
        }
        // 反证「淘汰确实跑了」：最冷的**另一本**照旧被清 ——
        // 否则上面那组断言可能在淘汰根本没执行时也成立（假绿）。
        XCTAssertEqual(otherChapters.first?.source, .notDownloaded)
    }

    private func cachedChapter(bookPath: String, number: Int) -> ChapterRecord {
        ChapterRecord(
            bookPath: bookPath,
            number: number,
            name: "第\(number)章",
            path: "\(bookPath)\(number).html",
            source: .cached,
            localFileName: "\(number).txt"
        )
    }
}
