import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 本地正文自愈测试：过期正文重新拉取、联网失败退回旧正文、落盘覆盖规则。
@MainActor
final class ReaderCacheHealTests: XCTestCase {
    private var container: ModelContainer?
    private var context: ModelContext?

    override func setUpWithError() throws {
        let container = try NovelStore.makeContainer(inMemory: true)
        self.container = container
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    // MARK: - 读侧：新鲜秒开、过期才联网、联网失败退回旧正文

    func test本地正文过期时重新拉取并返回网络正文() async throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(bookPath: "/heal/stale/")
        chapter.savedAt = Date(timeIntervalSince1970: 1000)
        context.insert(chapter)
        try context.save()
        try saveLocalText("旧的不完整正文", for: chapter)
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        let counter = FetchCounter()
        let text = try await ReaderLoaderLive.loadWithHeal(
            chapterPath: chapter.path,
            in: context,
            epoch: Date(timeIntervalSince1970: 2000)
        ) { path in
            await counter.record(path)
            return "完整的网络正文"
        }

        XCTAssertEqual(text, "完整的网络正文")
        let calls = await counter.callCount()
        XCTAssertEqual(calls, 1)
    }

    func test本地正文过期且联网失败时退回旧正文() async throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(bookPath: "/heal/stale-offline/")
        chapter.savedAt = Date(timeIntervalSince1970: 1000)
        context.insert(chapter)
        try context.save()
        try saveLocalText("旧的不完整正文", for: chapter)
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        let text = try await ReaderLoaderLive.loadWithHeal(
            chapterPath: chapter.path,
            in: context,
            epoch: Date(timeIntervalSince1970: 2000)
        ) { _ in
            throw HealTestError.offline
        }

        XCTAssertEqual(text, "旧的不完整正文")
    }

    func test本地正文新鲜时直接返回本地且不联网() async throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(bookPath: "/heal/fresh/")
        chapter.savedAt = Date(timeIntervalSince1970: 3000)
        context.insert(chapter)
        try context.save()
        try saveLocalText("新鲜正文", for: chapter)
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        let counter = FetchCounter()
        let text = try await ReaderLoaderLive.loadWithHeal(
            chapterPath: chapter.path,
            in: context,
            epoch: Date(timeIntervalSince1970: 2000)
        ) { path in
            await counter.record(path)
            return "网络正文"
        }

        XCTAssertEqual(text, "新鲜正文")
        let calls = await counter.callCount()
        XCTAssertEqual(calls, 0)
    }

    func test没有本地正文且联网失败时抛出错误() async throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(
            bookPath: "/heal/empty/",
            source: .notDownloaded,
            hasLocalText: false
        )
        context.insert(chapter)
        try context.save()

        do {
            _ = try await ReaderLoaderLive.loadWithHeal(
                chapterPath: chapter.path,
                in: context,
                epoch: Date(timeIntervalSince1970: 2000)
            ) { _ in
                throw HealTestError.offline
            }
            XCTFail("没有本地正文且联网失败时应当抛出错误")
        } catch {
            XCTAssertTrue(error is HealTestError)
        }
    }

    // MARK: - 写侧：只有正文真的变了才覆盖并刷新 savedAt

    func test待写正文与现有文件相同时不刷新savedAt() throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(bookPath: "/heal/same/")
        let oldSavedAt: Date? = Date(timeIntervalSince1970: 1000)
        chapter.savedAt = oldSavedAt
        context.insert(chapter)
        try context.save()
        try saveLocalText("同一份正文", for: chapter)
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        try ChapterCacheStoreLive.saveCachedText(
            "同一份正文",
            for: chapter,
            in: context,
            epoch: Date(timeIntervalSince1970: 2000)
        )

        XCTAssertEqual(chapter.savedAt, oldSavedAt)
        let onDisk = try NovelStore.loadChapterText(
            bookPath: chapter.bookPath,
            number: chapter.number
        )
        XCTAssertEqual(onDisk, "同一份正文")
    }

    func test待写正文与现有文件不同时覆盖并刷新savedAt() throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(bookPath: "/heal/different/")
        let oldSavedAt: Date? = Date(timeIntervalSince1970: 1000)
        chapter.savedAt = oldSavedAt
        context.insert(chapter)
        try context.save()
        try saveLocalText("截断的旧正文", for: chapter)
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        try ChapterCacheStoreLive.saveCachedText(
            "完整的正文",
            for: chapter,
            in: context,
            epoch: Date(timeIntervalSince1970: 2000)
        )

        let onDisk = try NovelStore.loadChapterText(
            bookPath: chapter.bookPath,
            number: chapter.number
        )
        XCTAssertEqual(onDisk, "完整的正文")
        XCTAssertNotEqual(chapter.savedAt, oldSavedAt)
        XCTAssertEqual(chapter.source, .cached)
    }

    func test已下载且新鲜时正文不被覆盖() throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(bookPath: "/heal/downloaded-fresh/", source: .downloaded)
        let oldSavedAt: Date? = Date(timeIntervalSince1970: 3000)
        chapter.savedAt = oldSavedAt
        context.insert(chapter)
        try context.save()
        try saveLocalText("用户下载的正文", for: chapter)
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        try ChapterCacheStoreLive.saveCachedText(
            "网络正文",
            for: chapter,
            in: context,
            epoch: Date(timeIntervalSince1970: 2000)
        )

        let onDisk = try NovelStore.loadChapterText(
            bookPath: chapter.bookPath,
            number: chapter.number
        )
        XCTAssertEqual(onDisk, "用户下载的正文")
        XCTAssertEqual(chapter.source, .downloaded)
        XCTAssertEqual(chapter.savedAt, oldSavedAt)
    }

    func test已下载且过期时被自愈覆盖且来源仍是已下载() throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(bookPath: "/heal/downloaded-stale/", source: .downloaded)
        let oldSavedAt: Date? = Date(timeIntervalSince1970: 1000)
        chapter.savedAt = oldSavedAt
        context.insert(chapter)
        try context.save()
        try saveLocalText("旧的不完整正文", for: chapter)
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        try ChapterCacheStoreLive.saveCachedText(
            "完整的网络正文",
            for: chapter,
            in: context,
            epoch: Date(timeIntervalSince1970: 2000)
        )

        let onDisk = try NovelStore.loadChapterText(
            bookPath: chapter.bookPath,
            number: chapter.number
        )
        XCTAssertEqual(onDisk, "完整的网络正文")
        XCTAssertEqual(chapter.source, .downloaded)
        XCTAssertNotEqual(chapter.savedAt, oldSavedAt)
    }

    // MARK: - 辅助

    private func makeChapter(
        bookPath: String,
        source: ChapterSource = .cached,
        hasLocalText: Bool = true
    ) -> ChapterRecord {
        ChapterRecord(
            bookPath: bookPath,
            number: 1,
            name: "第1章",
            path: "\(bookPath)1.html",
            source: source,
            localFileName: hasLocalText ? NovelStore.chapterFileName(number: 1) : nil
        )
    }

    private func saveLocalText(_ text: String, for chapter: ChapterRecord) throws {
        try NovelStore.saveChapterText(
            text,
            bookPath: chapter.bookPath,
            number: chapter.number
        )
    }
}

private actor FetchCounter {
    private var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }

    func callCount() -> Int {
        paths.count
    }
}

private enum HealTestError: Error {
    case offline
}
