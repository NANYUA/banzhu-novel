import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 阅读自动缓存与本地优先读取测试。
@MainActor
final class ChapterCacheStoreTests: XCTestCase {
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

    func test自动缓存当前与后续三章_跳过已下载和已有缓存() async throws {
        let context = try XCTUnwrap(context)
        let bookPath = "/cache/reader/"
        let chapter1 = makeChapter(bookPath: bookPath, number: 1, source: .notDownloaded)
        let chapter2 = makeChapter(
            bookPath: bookPath,
            number: 2,
            source: .downloaded,
            localFileName: "2.txt"
        )
        let chapter3 = makeChapter(
            bookPath: bookPath,
            number: 3,
            source: .cached,
            localFileName: "3.txt"
        )
        let chapter4 = makeChapter(bookPath: bookPath, number: 4, source: .notDownloaded)
        let chapter5 = makeChapter(bookPath: bookPath, number: 5, source: .notDownloaded)
        for chapter in [chapter1, chapter2, chapter3, chapter4, chapter5] {
            context.insert(chapter)
        }
        try context.save()

        let recorder = CacheRequestRecorder()
        await ChapterCacheStoreLive.cache(
            chapterPath: chapter1.path,
            currentText: "当前章正文",
            followingCount: 3,
            in: context
        ) { path in
            await recorder.record(path)
            return "正文：\(path)"
        }

        let requestedPaths = await recorder.allPaths()
        XCTAssertEqual(requestedPaths, [chapter4.path])
        XCTAssertEqual(chapter1.source, .cached)
        XCTAssertEqual(chapter4.source, .cached)
        XCTAssertEqual(chapter2.source, .downloaded)
        XCTAssertEqual(chapter3.source, .cached)
        XCTAssertEqual(chapter5.source, .notDownloaded)

        for number in [1, 4] {
            defer { NovelStore.deleteChapterText(bookPath: bookPath, number: number) }
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: NovelStore.chapterFile(bookPath: bookPath, number: number).path
                )
            )
        }
    }

    func test预缓存数量为零时只缓存当前章() async throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(
            bookPath: "/cache/reader/zero/",
            number: 1,
            source: .notDownloaded
        )
        let following = makeChapter(
            bookPath: chapter.bookPath,
            number: 2,
            source: .notDownloaded
        )
        context.insert(chapter)
        context.insert(following)
        try context.save()

        await ChapterCacheStoreLive.cache(
            chapterPath: chapter.path,
            currentText: "当前章正文",
            followingCount: 0,
            in: context
        ) { path in
            XCTFail("预缓存数量为零时不应请求 \(path)")
            return ""
        }

        XCTAssertEqual(chapter.source, .cached)
        XCTAssertEqual(following.source, .notDownloaded)
        NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number)
    }

    func test阅读优先读取本地缓存正文() throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(
            bookPath: "/cache/reader/local/",
            number: 1,
            source: .cached,
            localFileName: "1.txt"
        )
        context.insert(chapter)
        try context.save()
        try NovelStore.saveChapterText(
            "本地缓存正文",
            bookPath: chapter.bookPath,
            number: chapter.number
        )
        defer { NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number) }

        let text = try ReaderLoaderLive.load(chapterPath: chapter.path, in: context)

        XCTAssertEqual(text?.text, "本地缓存正文")
    }

    func test没有本地正文时不返回缓存结果() throws {
        let context = try XCTUnwrap(context)
        let chapter = makeChapter(
            bookPath: "/cache/reader/network/",
            number: 1,
            source: .notDownloaded
        )
        context.insert(chapter)
        try context.save()

        let text = try ReaderLoaderLive.load(chapterPath: chapter.path, in: context)

        XCTAssertNil(text)
    }

    private func makeChapter(
        bookPath: String,
        number: Int,
        source: ChapterSource,
        localFileName: String? = nil
    ) -> ChapterRecord {
        ChapterRecord(
            bookPath: bookPath,
            number: number,
            name: "第\(number)章",
            path: "\(bookPath)\(number).html",
            source: source,
            localFileName: localFileName
        )
    }
}

private actor CacheRequestRecorder {
    private var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }

    func allPaths() -> [String] {
        paths
    }
}
