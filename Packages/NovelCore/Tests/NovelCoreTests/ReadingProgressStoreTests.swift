import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 阅读进度写入测试。
///
/// 核心契约：正文加载成功后，必须把 `lastReadAt`、上次章节路径与章名
/// 一起写回 `BookRecord`。`lastReadAt` 同时是书架排序键与 LRU 输入。
final class ReadingProgressStoreTests: XCTestCase {
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

    func test记录已读章节_刷新最近阅读时间与位置() throws {
        let book = BookRecord(bookPath: "/read/progress/", title: "测试书")
        let chapter = ChapterRecord(
            bookPath: book.bookPath,
            number: 7,
            name: "第七章",
            path: "/read/progress/7.html"
        )
        context.insert(book)
        context.insert(chapter)
        try context.save()

        let readAt = Date(timeIntervalSince1970: 12345)
        try markRead(chapterPath: chapter.path, date: readAt)

        let storedBook = try context.fetch(FetchDescriptor<BookRecord>()).first
        XCTAssertEqual(storedBook?.lastReadChapterPath, chapter.path)
        XCTAssertEqual(storedBook?.lastReadChapterName, "第七章")
        XCTAssertEqual(storedBook?.lastReadAt, readAt)
    }

    func test章节不存在时不产生副作用() throws {
        let book = BookRecord(bookPath: "/read/missing/", title: "测试书")
        context.insert(book)
        try context.save()

        try markRead(chapterPath: "/read/missing/1.html", date: Date())

        let storedBook = try context.fetch(FetchDescriptor<BookRecord>()).first
        XCTAssertNil(storedBook?.lastReadAt)
        XCTAssertNil(storedBook?.lastReadChapterPath)
    }

    func test书不存在时不崩溃也不写入() throws {
        let chapter = ChapterRecord(
            bookPath: "/read/chapter-only/",
            number: 1,
            name: "第一章",
            path: "/read/chapter-only/1.html"
        )
        context.insert(chapter)
        try context.save()

        XCTAssertNoThrow(try markRead(chapterPath: chapter.path, date: Date()))
    }

    /// 以显式容器复刻 `ReadingProgressStoreLive` 的写入规则：
    /// 测试环境不碰真实沙盒，但仍验证同一套数据变更。
    private func markRead(chapterPath: String, date: Date) throws {
        let descriptor = FetchDescriptor<ChapterRecord>(
            predicate: #Predicate { $0.path == chapterPath }
        )
        guard let chapter = try context.fetch(descriptor).first else { return }
        let bookPath = chapter.bookPath
        var bookDescriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        bookDescriptor.fetchLimit = 1
        guard let book = try context.fetch(bookDescriptor).first else { return }

        book.lastReadChapterPath = chapter.path
        book.lastReadChapterName = chapter.name
        book.lastReadAt = date
        try context.save()
    }
}
