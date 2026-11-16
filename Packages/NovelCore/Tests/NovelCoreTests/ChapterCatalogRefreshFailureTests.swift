import Foundation
@testable import NovelCore
import NovelEngine
import SwiftData
import XCTest

@MainActor
final class ChapterCatalogRefreshFailureTests: XCTestCase {
    func test网络失败不会创建存储上下文或写入部分目录() async throws {
        let fixture = try CatalogRefreshFixture()
        var createdContext = false
        do {
            _ = try await ChapterCatalogRefresherLive.refresh(
                bookPath: fixture.bookPath,
                load: { path in
                    XCTAssertEqual(path, fixture.bookPath)
                    throw CatalogTestFailure.expected
                },
                makeContext: {
                    createdContext = true
                    return ModelContext(fixture.container)
                }
            )
            XCTFail("网络失败时应抛出错误")
        } catch {
            XCTAssertEqual(error as? CatalogTestFailure, .expected)
        }
        XCTAssertFalse(createdContext)
        try assertOriginalSnapshot(fixture)
    }

    func test抓取完成后读取最新下载状态() async throws {
        let fixture = try CatalogRefreshFixture()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: NovelStore.bookDir(forBookPath: fixture.bookPath)))
        }
        var fetched = false
        let result = try await ChapterCatalogRefresherLive.refresh(
            bookPath: fixture.bookPath,
            load: { _ in
                _ = try fixture.saveText(number: 1, source: .downloaded, text: "刚下载的正文")
                fetched = true
                return fixture.remote(Array(1 ... 100))
            },
            makeContext: {
                XCTAssertTrue(fetched)
                return ModelContext(fixture.container)
            }
        )
        XCTAssertEqual(result.first?.isDownloaded, true)
        XCTAssertEqual(result.first?.hasLocalText, true)
        XCTAssertEqual(result.count, 100)
        XCTAssertEqual(try NovelStore.loadChapterText(bookPath: fixture.bookPath, number: 1), "刚下载的正文")
    }

    func test空目录不改变已有快照() throws {
        let fixture = try CatalogRefreshFixture()
        XCTAssertThrowsError(try fixture.merge([])) {
            XCTAssertEqual($0 as? ChapterCatalogRefreshError, .emptyCatalog)
        }
        try assertOriginalSnapshot(fixture)
    }

    func test未上架书不能写入目录() throws {
        let fixture = try CatalogRefreshFixture()
        fixture.context.delete(fixture.book)
        try fixture.context.save()
        XCTAssertThrowsError(try fixture.merge(fixture.remote([26]))) {
            XCTAssertEqual($0 as? ChapterCatalogRefreshError, .bookNotOnShelf)
        }
        XCTAssertEqual(try fixture.storedChapters().count, 26)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<BookRecord>()).isEmpty)
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func test本地及远端身份冲突均在修改对象前拒绝() throws {
        let fixture = try CatalogRefreshFixture()
        let cases = [
            ConflictCase(
                chapters: [Chapter(number: 1, name: "冲突", path: fixture.path(101))],
                error: .conflictingNumber(1)
            ),
            ConflictCase(
                chapters: [Chapter(number: 101, name: "冲突", path: fixture.path(1))],
                error: .conflictingPath(fixture.path(1))
            ),
            ConflictCase(
                chapters: [Chapter(number: 26, name: "冲突", path: fixture.path(27))],
                error: .conflictingNumber(26)
            ),
            ConflictCase(
                chapters: [Chapter(number: 27, name: "冲突", path: fixture.path(26))],
                error: .conflictingPath(fixture.path(26))
            ),
        ]
        let prefix = [Chapter(number: 1, name: "不应写入的章名", path: fixture.path(1))]
            + fixture.remote([26])
        for testCase in cases {
            XCTAssertThrowsError(try fixture.merge(prefix + testCase.chapters)) {
                XCTAssertEqual($0 as? ChapterCatalogRefreshError, testCase.error)
            }
            try assertOriginalSnapshot(fixture)
        }
    }

    func test保存失败回滚且不影响其他上下文的编辑() throws {
        let fixture = try CatalogRefreshFixture()
        let otherContext = ModelContext(fixture.container)
        otherContext.autosaveEnabled = false
        let otherBook = try XCTUnwrap(otherContext.fetch(FetchDescriptor<BookRecord>()).first)
        otherBook.title = "未保存的编辑"
        let chapters = [Chapter(number: 1, name: "待回滚章名", path: fixture.path(1))]
            + fixture.remote([26])
        XCTAssertThrowsError(try ChapterCatalogRefresherLive.merge(
            chapters: chapters, bookPath: fixture.bookPath, context: fixture.context,
            save: { context in
                XCTAssertTrue(context.hasChanges)
                throw CatalogTestFailure.expected
            }
        )) {
            XCTAssertEqual($0 as? CatalogTestFailure, .expected)
        }
        try assertOriginalSnapshot(fixture)
        XCTAssertEqual(otherBook.title, "未保存的编辑")
        XCTAssertTrue(otherContext.hasChanges)
        let readingContext = ModelContext(fixture.container)
        let persisted = try XCTUnwrap(readingContext.fetch(FetchDescriptor<BookRecord>()).first)
        XCTAssertEqual(persisted.title, "测试书")
        XCTAssertEqual(try fixture.merge(fixture.remote([26])).count, 27)
    }

    func test拒绝包含未保存修改的上下文且不回滚这些修改() throws {
        let fixture = try CatalogRefreshFixture()
        fixture.book.title = "尚未保存"
        XCTAssertThrowsError(try fixture.merge(fixture.remote([26]))) {
            XCTAssertEqual($0 as? ChapterCatalogRefreshError, .pendingChanges)
        }
        XCTAssertEqual(fixture.book.title, "尚未保存")
        XCTAssertTrue(fixture.context.hasChanges)
        XCTAssertEqual(try fixture.storedChapters().count, 26)
        XCTAssertEqual(fixture.book.latestChapterCount, 26)
    }

    private func assertOriginalSnapshot(_ fixture: CatalogRefreshFixture) throws {
        XCTAssertFalse(fixture.context.hasChanges)
        let chapters = try fixture.storedChapters()
        XCTAssertEqual(chapters.map(\.number), Array(1 ... 25) + [100])
        XCTAssertEqual(chapters.first?.name, "第1章")
        XCTAssertEqual(fixture.book.latestChapterName, "第100章")
        XCTAssertEqual(fixture.book.latestChapterCount, 26)
        XCTAssertEqual(fixture.book.lastCheckedAt, Date(timeIntervalSince1970: 200))
        let context = ModelContext(fixture.container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChapterRecord>()).count, 26)
        let book = try XCTUnwrap(context.fetch(FetchDescriptor<BookRecord>()).first)
        XCTAssertEqual(book.latestChapterName, "第100章")
        XCTAssertEqual(book.latestChapterCount, 26)
        XCTAssertEqual(book.lastCheckedAt, Date(timeIntervalSince1970: 200))
    }
}

private struct ConflictCase {
    let chapters: [Chapter]
    let error: ChapterCatalogRefreshError
}

private enum CatalogTestFailure: Error, Equatable {
    case expected
}
