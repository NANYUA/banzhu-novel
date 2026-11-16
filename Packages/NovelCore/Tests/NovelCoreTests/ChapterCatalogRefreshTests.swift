import Foundation
@testable import NovelCore
import NovelEngine
import SwiftData
import XCTest

@MainActor
final class ChapterCatalogRefreshTests: XCTestCase {
    func test补全缺页目录且重复刷新不重复插入() throws {
        let fixture = try CatalogRefreshFixture()
        let before = try fixture.storedChapters()
        XCTAssertEqual(ChapterCachePlanner.planFollowing(
            currentChapterPath: fixture.path(25), chapters: before, followingCount: 1
        ).map(\.number), [100])

        let chapters = fixture.remote(Array((1 ... 100).reversed()))
        let result = try fixture.merge(chapters)
        XCTAssertEqual(result.map(\.number), Array(1 ... 100))
        XCTAssertEqual(Set(result.map(\.path)).count, 100)
        XCTAssertEqual(fixture.book.latestChapterCount, 100)
        XCTAssertEqual(fixture.book.latestChapterName, "第100章")
        XCTAssertNotNil(fixture.book.lastCheckedAt)
        XCTAssertTrue(result.allSatisfy { !$0.hasLocalText && !$0.isDownloaded })

        let merged = try fixture.storedChapters()
        XCTAssertEqual(ChapterCachePlanner.planFollowing(
            currentChapterPath: fixture.path(25), chapters: merged, followingCount: 1
        ).map(\.number), [26])
        for chapter in before {
            XCTAssertEqual(chapter.id, ChapterRecord.makeId(bookPath: fixture.bookPath, number: chapter.number))
            XCTAssertTrue(merged.contains { $0.persistentModelID == chapter.persistentModelID })
        }
        let repeated = try fixture.merge(chapters + chapters)
        XCTAssertEqual(repeated, result)
        XCTAssertEqual(try fixture.storedChapters().count, 100)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func test补全后阅读器相邻章不再跨过缺页() throws {
        let fixture = try CatalogRefreshFixture()
        var reader = ReaderFeature.State(
            chapterPath: fixture.path(25),
            chapters: try fixture.storedChapters().map { ChapterItem(record: $0) }
        )
        XCTAssertEqual(reader.nextChapter?.path, fixture.path(100))

        reader.chapters = try fixture.merge(fixture.remote(Array(1 ... 100)))
        XCTAssertEqual(reader.nextChapter?.path, fixture.path(26))
        XCTAssertEqual(reader.previousChapter?.path, fixture.path(24))
        reader.chapterPath = fixture.path(26)
        XCTAssertEqual(reader.previousChapter?.path, fixture.path(25))
        XCTAssertEqual(reader.nextChapter?.path, fixture.path(27))
    }

    func test刷新保留下载缓存标记时间及正文() throws {
        let fixture = try CatalogRefreshFixture()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: NovelStore.bookDir(forBookPath: fixture.bookPath)))
        }
        let downloaded = try fixture.saveText(number: 1, source: .downloaded, text: "下载正文")
        let cached = try fixture.saveText(number: 2, source: .cached, text: "缓存正文")
        let savedAt = Date(timeIntervalSince1970: 123)
        downloaded.savedAt = savedAt
        cached.savedAt = savedAt
        try fixture.context.save()

        let result = try fixture.merge(fixture.remote(Array(1 ... 100)))
        XCTAssertEqual(downloaded.source, .downloaded)
        XCTAssertEqual(cached.source, .cached)
        for chapter in [downloaded, cached] {
            XCTAssertEqual(chapter.savedAt, savedAt)
            XCTAssertEqual(chapter.localFileName, "\(chapter.number).txt")
        }
        XCTAssertEqual(result.first?.isDownloaded, true)
        XCTAssertEqual(result.first?.hasLocalText, true)
        XCTAssertEqual(result.dropFirst().first?.isDownloaded, false)
        XCTAssertEqual(result.dropFirst().first?.hasLocalText, true)
        let readingContext = ModelContext(fixture.container)
        let epoch = Date(timeIntervalSince1970: 200)
        let downloadedText = try XCTUnwrap(ReaderLoaderLive.load(
            chapterPath: downloaded.path, in: readingContext, epoch: epoch
        ))
        let cachedText = try XCTUnwrap(ReaderLoaderLive.load(
            chapterPath: cached.path, in: readingContext, epoch: epoch
        ))
        XCTAssertEqual(downloadedText.text, "下载正文")
        XCTAssertEqual(cachedText.text, "缓存正文")
        XCTAssertTrue(downloadedText.isStale)
        XCTAssertTrue(cachedText.isStale)
    }

    func test刷新保留阅读位置分组加入时间及下载任务() throws {
        let fixture = try CatalogRefreshFixture()
        let book = fixture.book
        let groupID = UUID()
        let readAt = Date(timeIntervalSince1970: 456)
        let addedAt = book.addedAt
        book.groupId = groupID
        book.lastReadChapterPath = fixture.path(25)
        book.lastReadChapterName = "第25章"
        book.lastReadOffset = 42
        book.lastReadAt = readAt
        let task = DownloadTask(
            bookPath: fixture.bookPath, bookTitle: book.title,
            chapterPath: fixture.path(100), chapterName: "第100章",
            chapterNumber: 100, state: .paused
        )
        task.attempts = 2
        task.lastError = "网络暂不可用"
        fixture.context.insert(task)
        try fixture.context.save()
        let taskBefore = DownloadTaskSnapshot(task: task)

        _ = try fixture.merge(fixture.remote(Array(1 ... 100)))
        let readingContext = ModelContext(fixture.container)
        let storedBook = try XCTUnwrap(readingContext.fetch(FetchDescriptor<BookRecord>()).first)
        XCTAssertEqual(storedBook.groupId, groupID)
        XCTAssertEqual(storedBook.addedAt, addedAt)
        XCTAssertEqual(storedBook.lastReadChapterPath, fixture.path(25))
        XCTAssertEqual(storedBook.lastReadChapterName, "第25章")
        XCTAssertEqual(storedBook.lastReadOffset, 42)
        XCTAssertEqual(storedBook.lastReadAt, readAt)
        let tasks = try readingContext.fetch(FetchDescriptor<DownloadTask>())
        XCTAssertEqual(tasks.map { DownloadTaskSnapshot(task: $0) }, [taskBefore])
    }

    func test未返回的旧章节保留且只更新本书() throws {
        let fixture = try CatalogRefreshFixture()
        let otherBook = BookRecord(bookPath: "/catalog/other/", title: "另一本书")
        let otherChapter = ChapterRecord(
            bookPath: otherBook.bookPath, number: 26, name: "另一章", path: "/catalog/other/26.html"
        )
        fixture.context.insert(otherBook)
        fixture.context.insert(otherChapter)
        try fixture.context.save()
        let renamed = Chapter(number: 1, name: "新的章名", path: fixture.path(1))

        let result = try fixture.merge([renamed] + fixture.remote([26]))
        XCTAssertEqual(result.map(\.number), Array(1 ... 26) + [100])
        XCTAssertEqual(result.first?.name, "新的章名")
        XCTAssertEqual(fixture.book.latestChapterCount, 27)
        XCTAssertEqual(fixture.book.latestChapterName, "第100章")
        XCTAssertEqual(otherChapter.name, "另一章")
        XCTAssertEqual(otherBook.latestChapterCount, 0)
        XCTAssertNil(otherBook.lastCheckedAt)
    }
}

@MainActor
struct CatalogRefreshFixture {
    let container: ModelContainer
    let context: ModelContext
    let book: BookRecord
    let bookPath: String

    init() throws {
        let container = try NovelStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let bookPath = "/catalog/\(UUID().uuidString)/"
        let book = BookRecord(
            bookPath: bookPath, title: "测试书", addedAt: Date(timeIntervalSince1970: 100)
        )
        book.latestChapterName = "第100章"
        book.latestChapterCount = 26
        book.lastCheckedAt = Date(timeIntervalSince1970: 200)
        context.insert(book)
        for number in Array(1 ... 25) + [100] {
            context.insert(ChapterRecord(
                bookPath: bookPath, number: number, name: "第\(number)章",
                path: "\(bookPath)\(number).html"
            ))
        }
        try context.save()
        self.container = container
        self.context = context
        self.book = book
        self.bookPath = bookPath
    }

    func path(_ number: Int) -> String {
        "\(bookPath)\(number).html"
    }

    func remote(_ numbers: [Int]) -> [Chapter] {
        numbers.map { Chapter(number: $0, name: "第\($0)章", path: path($0)) }
    }

    func storedChapters() throws -> [ChapterRecord] {
        try context.fetch(FetchDescriptor<ChapterRecord>())
            .filter { $0.bookPath == bookPath }
            .sorted { $0.number < $1.number }
    }

    func merge(_ chapters: [Chapter]) throws -> [ChapterItem] {
        try ChapterCatalogRefresherLive.merge(chapters: chapters, bookPath: bookPath, context: context)
    }

    func saveText(number: Int, source: ChapterSource, text: String) throws -> ChapterRecord {
        let chapter = try XCTUnwrap(storedChapters().first { $0.number == number })
        chapter.localFileName = try NovelStore.saveChapterText(text, bookPath: bookPath, number: number)
        chapter.source = source
        try context.save()
        return chapter
    }
}
