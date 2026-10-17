import Foundation
@testable import NovelCore
import SwiftData
import XCTest

/// 导入管线端到端测试：读文件 → 解码 → 切章 → 落盘 → 落库。
///
/// 用**内存容器**（不污染真实书架）+ 临时目录里的真文件（正文落盘走的是真实 `NovelStore`，
/// 没有可注入的根目录）。每个测试结束都把写出去的正文目录删掉。
@MainActor
final class LocalBookImporterTests: XCTestCase {
    private var container: ModelContainer!
    private var fileURL: URL!

    override func setUpWithError() throws {
        container = try NovelStore.makeContainer(inMemory: true)
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("txt-import-\(UUID().uuidString).txt")
    }

    override func tearDownWithError() throws {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        container = nil
    }

    private func writeFile(_ text: String) throws {
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func runImport(title: String, author: String = "") async throws -> ImportResult {
        let request = ImportRequest(
            fileURL: fileURL,
            title: title,
            author: author,
            rules: BuiltinImportRules.all
        )
        return try await LocalBookImporterLive.perform(
            request: request,
            onProgress: { _ in },
            container: container
        )
    }

    func test导入两章_落库与落盘都正确() async throws {
        try writeFile("第一章 起点\n第一段内容。\n第二章 终点\n第二段内容。\n")
        let result = try await runImport(title: "测试书", author: "某某")
        defer { cleanup(result.bookPath) }

        XCTAssertTrue(LocalBookPath.isLocal(result.bookPath), "本地书必须带 local/ 前缀")
        XCTAssertEqual(result.chapterCount, 2)
        XCTAssertEqual(result.title, "测试书")

        let context = ModelContext(container)
        let books = try context.fetch(FetchDescriptor<BookRecord>())
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.bookPath, result.bookPath)
        XCTAssertEqual(books.first?.title, "测试书")
        XCTAssertEqual(books.first?.author, "某某")
        // 目录快照：书架离线也要能显示「最新章节 / 共 N 章」
        XCTAssertEqual(books.first?.latestChapterName, "第二章 终点")
        XCTAssertEqual(books.first?.latestChapterCount, 2)

        let descriptor = FetchDescriptor<ChapterRecord>(sortBy: [SortDescriptor(\.number)])
        let chapters = try context.fetch(descriptor)
        XCTAssertEqual(chapters.map(\.number), [1, 2])
        XCTAssertEqual(chapters.map(\.name), ["第一章 起点", "第二章 终点"])
        XCTAssertEqual(chapters.map(\.path), [
            LocalBookPath.chapterPath(bookPath: result.bookPath, number: 1),
            LocalBookPath.chapterPath(bookPath: result.bookPath, number: 2),
        ])
        // 🔴 契约 ①：导入的章必须是 .downloaded（不是 .cached），否则会被 LRU 当缓存删掉
        XCTAssertTrue(chapters.allSatisfy { $0.source == .downloaded })
        XCTAssertTrue(chapters.allSatisfy(\.hasLocalText))

        XCTAssertEqual(
            try NovelStore.loadChapterText(bookPath: result.bookPath, number: 1),
            "第一段内容。"
        )
        XCTAssertEqual(
            try NovelStore.loadChapterText(bookPath: result.bookPath, number: 2),
            "第二段内容。"
        )
    }

    func test重复导入同一文件_报已在书架() async throws {
        try writeFile("第一章 起点\n第一段内容。\n")
        let first = try await runImport(title: "测试书")
        defer { cleanup(first.bookPath) }

        do {
            _ = try await runImport(title: "测试书")
            XCTFail("同一份内容第二次导入应当被拦下")
        } catch let error as ImportError {
            XCTAssertEqual(error, .alreadyExists(title: "测试书"))
        }
    }

    func test空文件_报没有正文() async throws {
        try writeFile("   \n\n  ")
        do {
            _ = try await runImport(title: "空书")
            XCTFail("空白文件不该导入成功")
        } catch let error as ImportError {
            XCTAssertEqual(error, .noContent(fileName: fileURL.deletingPathExtension().lastPathComponent))
        }
    }

    func test书名留空_用文件名兜底() async throws {
        try writeFile("第一章 起点\n第一段内容。\n")
        let result = try await runImport(title: "   ")
        defer { cleanup(result.bookPath) }
        XCTAssertEqual(result.title, fileURL.deletingPathExtension().lastPathComponent)
    }

    /// 🔴 契约 ②：整本书都是 .downloaded ⇒ 缓存淘汰一个字节都不该动它。
    func test导入书永不被缓存淘汰() async throws {
        try writeFile("第一章 起点\n第一段内容。\n第二章 终点\n第二段内容。\n")
        let result = try await runImport(title: "测试书")
        defer { cleanup(result.bookPath) }

        let context = ModelContext(container)
        // maxCachedBooks 设为 0：任何带 .cached 章节的书都会被规划淘汰，
        // 导入书一条都不该命中。
        try NovelStore.evictCachedChapters(in: context, maxCachedBooks: 0)

        let chapters = try context.fetch(FetchDescriptor<ChapterRecord>())
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters.allSatisfy { $0.source == .downloaded })
        XCTAssertEqual(
            try NovelStore.loadChapterText(bookPath: result.bookPath, number: 1),
            "第一段内容。",
            "正文文件也不该被删"
        )
    }

    private func cleanup(_ bookPath: String) {
        try? FileManager.default.removeItem(at: NovelStore.bookDir(forBookPath: bookPath))
    }
}
