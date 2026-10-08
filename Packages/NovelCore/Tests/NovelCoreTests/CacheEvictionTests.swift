import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 章节级 LRU 缓存淘汰测试。
///
/// 核心约束：可以按书选择，但只能删 `.cached` 章节；
/// `.downloaded` 和 `.notDownloaded` 都不参与淘汰。
final class CacheEvictionTests: XCTestCase {
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

    func test默认缓存上限为十本() {
        XCTAssertEqual(NovelStore.defaultMaxCachedBooks, 10)
    }

    func test缓存未超上限时不淘汰() throws {
        let first = BookRecord(bookPath: "/cache/lru/first/", title: "第一本")
        first.lastReadAt = Date(timeIntervalSince1970: 1000)
        let second = BookRecord(bookPath: "/cache/lru/second/", title: "第二本")
        second.lastReadAt = Date(timeIntervalSince1970: 2000)
        let firstChapter = cachedChapter(bookPath: first.bookPath, number: 1)
        let secondChapter = cachedChapter(bookPath: second.bookPath, number: 1)
        context.insert(first); context.insert(second)
        context.insert(firstChapter); context.insert(secondChapter)
        try context.save()

        let plans = try NovelStore.evictCachedChapters(in: context, maxCachedBooks: 2)

        XCTAssertTrue(plans.isEmpty)
        XCTAssertEqual(firstChapter.source, .cached)
        XCTAssertEqual(secondChapter.source, .cached)
    }

    func test超上限时淘汰最早阅读的书_只清缓存并保留下载章() throws {
        let oldBookPath = "/cache/lru/old/"
        let recentBookPath = "/cache/lru/recent/"
        let old = BookRecord(bookPath: oldBookPath, title: "最早读过")
        old.lastReadAt = Date(timeIntervalSince1970: 1000)
        let recent = BookRecord(bookPath: recentBookPath, title: "最近读过")
        recent.lastReadAt = Date(timeIntervalSince1970: 9000)

        let downloaded = ChapterRecord(
            bookPath: oldBookPath, number: 1, name: "第一章", path: "/old/1.html",
            source: .downloaded, localFileName: "1.txt"
        )
        let cached = cachedChapter(bookPath: oldBookPath, number: 51)
        let laterCached = cachedChapter(bookPath: oldBookPath, number: 52)
        let recentCached = cachedChapter(bookPath: recentBookPath, number: 1)
        let downloadedFile = NovelStore.chapterFile(bookPath: oldBookPath, number: 1)
        let cachedFile = NovelStore.chapterFile(bookPath: oldBookPath, number: 51)
        try NovelStore.saveChapterText("用户下载", bookPath: oldBookPath, number: 1)
        try NovelStore.saveChapterText("自动缓存", bookPath: oldBookPath, number: 51)
        defer { NovelStore.deleteChapterText(bookPath: oldBookPath, number: 1) }

        context.insert(old); context.insert(recent)
        context.insert(downloaded); context.insert(cached); context.insert(laterCached)
        context.insert(recentCached)
        try context.save()

        let plans = try NovelStore.evictCachedChapters(in: context, maxCachedBooks: 1)

        XCTAssertEqual(plans, [
            CacheEvictionPlan(bookPath: oldBookPath, chapterIDs: [cached.id, laterCached.id]),
        ])
        XCTAssertEqual(cached.source, .notDownloaded)
        XCTAssertEqual(laterCached.source, .notDownloaded)
        XCTAssertFalse(cached.hasLocalText)
        XCTAssertFalse(laterCached.hasLocalText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedFile.path))
        XCTAssertEqual(downloaded.source, .downloaded)
        XCTAssertTrue(downloaded.hasLocalText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedFile.path))
        XCTAssertEqual(recentCached.source, .cached)
    }

    func test缓存清空后该书退出缓存计数() throws {
        let first = BookRecord(bookPath: "/cache/lru/exit/first/", title: "第一本")
        first.lastReadAt = Date(timeIntervalSince1970: 1000)
        let second = BookRecord(bookPath: "/cache/lru/exit/second/", title: "第二本")
        second.lastReadAt = Date(timeIntervalSince1970: 2000)
        let third = BookRecord(bookPath: "/cache/lru/exit/third/", title: "第三本")
        third.lastReadAt = Date(timeIntervalSince1970: 3000)
        context.insert(first); context.insert(second); context.insert(third)
        context.insert(cachedChapter(bookPath: first.bookPath, number: 1))
        context.insert(cachedChapter(bookPath: second.bookPath, number: 1))
        context.insert(cachedChapter(bookPath: third.bookPath, number: 1))
        try context.save()

        let firstPlans = try NovelStore.evictCachedChapters(in: context, maxCachedBooks: 2)
        let secondPlans = try NovelStore.evictCachedChapters(in: context, maxCachedBooks: 2)

        XCTAssertEqual(firstPlans.map(\.bookPath), [first.bookPath])
        XCTAssertTrue(secondPlans.isEmpty, "缓存清空后的书不能再占用 LRU 名额")
    }

    func test只有自动缓存计入上限_用户下载不参与计数() throws {
        let downloadedBookPath = "/cache/lru/download-only/"
        let first = BookRecord(bookPath: downloadedBookPath, title: "只有下载")
        first.lastReadAt = Date(timeIntervalSince1970: 1000)
        let second = BookRecord(bookPath: "/cache/lru/cached-second/", title: "缓存一")
        second.lastReadAt = Date(timeIntervalSince1970: 2000)
        let third = BookRecord(bookPath: "/cache/lru/cached-third/", title: "缓存二")
        third.lastReadAt = Date(timeIntervalSince1970: 3000)
        let downloaded = ChapterRecord(
            bookPath: downloadedBookPath, number: 1, name: "第一章", path: "/download-only/1.html",
            source: .downloaded, localFileName: "1.txt"
        )
        context.insert(first); context.insert(second); context.insert(third); context.insert(downloaded)
        context.insert(cachedChapter(bookPath: second.bookPath, number: 1))
        context.insert(cachedChapter(bookPath: third.bookPath, number: 1))
        try context.save()

        let plans = try NovelStore.evictCachedChapters(in: context, maxCachedBooks: 2)

        XCTAssertTrue(plans.isEmpty)
        XCTAssertEqual(downloaded.source, .downloaded)
    }

    func test未下载记录不计入缓存且不参与淘汰() throws {
        let first = BookRecord(bookPath: "/cache/lru/not-downloaded-first/", title: "第一本")
        first.lastReadAt = Date(timeIntervalSince1970: 1000)
        let second = BookRecord(bookPath: "/cache/lru/not-downloaded-second/", title: "第二本")
        second.lastReadAt = Date(timeIntervalSince1970: 2000)
        let notDownloaded = ChapterRecord(
            bookPath: first.bookPath, number: 1, name: "第一章", path: "/not-downloaded/1.html"
        )
        context.insert(first); context.insert(second); context.insert(notDownloaded)
        context.insert(cachedChapter(bookPath: second.bookPath, number: 1))
        try context.save()

        let plans = try NovelStore.evictCachedChapters(in: context, maxCachedBooks: 1)

        XCTAssertTrue(plans.isEmpty)
        XCTAssertEqual(notDownloaded.source, .notDownloaded)
    }

    func test从未读过的缓存按最旧处理() {
        let neverRead = BookRecord(bookPath: "/cache/lru/never/", title: "没读过")
        let read = BookRecord(bookPath: "/cache/lru/read/", title: "读过")
        read.lastReadAt = Date(timeIntervalSince1970: 1000)
        let neverChapter = cachedChapter(bookPath: neverRead.bookPath, number: 1)
        let readChapter = cachedChapter(bookPath: read.bookPath, number: 1)

        let plans = CacheEvictionPlanner.plan(
            books: [read, neverRead],
            chapters: [neverChapter, readChapter],
            maxCachedBooks: 1
        )

        XCTAssertEqual(plans.map(\.bookPath), [neverRead.bookPath])
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
