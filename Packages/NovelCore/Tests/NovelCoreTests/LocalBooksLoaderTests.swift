import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 「本地」页那段本地导入书列表的数据来源测试。
///
/// 判据只有一条：`LocalBookPath.isLocal(_:)`。这里同时放一本站点书当反例 ——
/// 若判据被改宽（例如「没有封面 / host 为空」），反例就会漏进本地列表。
@MainActor
final class LocalBooksLoaderTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try NovelStore.makeContainer(inMemory: true)
    }

    override func tearDownWithError() throws {
        container = nil
    }

    private func insert(
        bookPath: String,
        title: String,
        addedAt: Date = Date(),
        lastReadChapterName: String? = nil
    ) throws {
        let context = ModelContext(container)
        let record = BookRecord(bookPath: bookPath, title: title, author: "作者", addedAt: addedAt)
        record.latestChapterCount = 3
        record.lastReadChapterName = lastReadChapterName
        context.insert(record)
        try context.save()
    }

    func test只返回本地书_站点书被排除() throws {
        try insert(bookPath: "local/0123456789abcdef/", title: "本地书")
        try insert(bookPath: "/1/2/", title: "站点书")

        let rows = LocalBooksLoaderLive.rows(from: ModelContext(container))

        XCTAssertEqual(rows.map(\.title), ["本地书"])
        XCTAssertEqual(rows.first?.bookPath, "local/0123456789abcdef/")
    }

    func test按导入时间倒序_并带出章节数与读到哪一章() throws {
        try insert(
            bookPath: "local/aaaaaaaaaaaaaaaa/",
            title: "早导入",
            addedAt: Date(timeIntervalSince1970: 100),
            lastReadChapterName: "第 1 章"
        )
        try insert(
            bookPath: "local/bbbbbbbbbbbbbbbb/",
            title: "晚导入",
            addedAt: Date(timeIntervalSince1970: 200)
        )

        let rows = LocalBooksLoaderLive.rows(from: ModelContext(container))

        XCTAssertEqual(rows.map(\.title), ["晚导入", "早导入"])
        XCTAssertEqual(rows.last?.chapterCount, 3)
        XCTAssertEqual(rows.last?.lastReadChapterName, "第 1 章")
        XCTAssertNil(rows.first?.lastReadChapterName)
    }

    func test空库返回空表() {
        XCTAssertTrue(LocalBooksLoaderLive.rows(from: ModelContext(container)).isEmpty)
    }
}
