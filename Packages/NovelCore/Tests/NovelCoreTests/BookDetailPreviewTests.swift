import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 「搜索入口点进详情」这条链路的回归测试。
///
/// 真机缺陷：搜索点书进详情 → 简介为空、目录为空、也点不进阅读；
/// 先「加入书架」再重进才正常。
///
/// 成因不是接线漏了，而是**首屏数据只有一个来源**：详情与目录都只读本地快照
/// （`BookRecord` / `ChapterRecord`），而这两张表只有「加入书架」才会写 ——
/// 未上架的书首屏必然空。书架入口之所以正常，只是因为那里的书都已经在书架上。
/// 本文件守的就是那条共用兜底：本地读不到时由 `BookDetailLoader.preview` 远端补齐，
/// **且不能**因此把这本书算成「已在书架」。
@MainActor
final class BookDetailPreviewTests: XCTestCase {
    private static let bookPath = "/49/49034/"
    private static let otherBookPath = "/49/49035/"
    private static let fallback = BookDetail(bookPath: bookPath, title: "搜索结果")

    /// 远端兜底回来的详情：搜索列表给不出简介（列表页解析没有这个字段）。
    private static let remoteDetail = BookDetail(
        bookPath: bookPath,
        title: "远端书名",
        author: "远端作者",
        intro: "远端简介",
        lastChapter: "第十二章"
    )

    /// 远端兜底回来的目录行：本地还没有正文，也没被用户下载过。
    private static func makeChapter(
        number: Int,
        bookPath: String = BookDetailPreviewTests.bookPath
    ) -> ChapterItem {
        ChapterItem(
            number: number,
            name: "第 \(number) 章",
            path: "\(bookPath)\(number).html",
            hasLocalText: false,
            isDownloaded: false
        )
    }

    // MARK: - 搜索入口的首屏兜底

    func test搜索入口未上架时首屏由远端兜底补齐详情与目录() async {
        let chapters = [Self.makeChapter(number: 1), Self.makeChapter(number: 2)]
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            // 搜索路径：本地既没有这本书的记录，目录快照也是空的。
            $0.bookDetailLoader.load = { bookPath in
                XCTAssertEqual(bookPath, Self.bookPath)
                return nil
            }
            $0.chapterListLoader.load = { bookPath in
                XCTAssertEqual(bookPath, Self.bookPath)
                return []
            }
            $0.bookDetailLoader.preview = { bookPath in
                XCTAssertEqual(bookPath, Self.bookPath)
                return BookPreview(detail: Self.remoteDetail, chapters: chapters)
            }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        await store.receive(.chaptersLoaded([])) {
            $0.isLoadingChapters = false
        }
        await store.receive(.previewLoaded(detail: Self.remoteDetail, chapters: chapters)) {
            $0.detail = Self.remoteDetail
            $0.chapters = chapters
        }

        // 首屏被填满：简介有了、目录有了 —— 「开始阅读」因此才出得来。
        XCTAssertEqual(store.state.detail.intro, "远端简介")
        XCTAssertEqual(store.state.chapters.count, 2)
        XCTAssertEqual(store.state.visibleChapters.count, 2)
        XCTAssertEqual(store.state.detail.bookPath, Self.bookPath)
        // 兜底是现场从网络拿的，不代表这本书进了书架 —— 按钮必须还是「加入书架」。
        XCTAssertFalse(store.state.isOnShelf)
        await store.finish()
    }

    func test已上架的书本地就有数据不走远端兜底() async {
        let local = BookDetail(bookPath: Self.bookPath, title: "本地书名", intro: "本地简介")
        let localChapters = [Self.makeChapter(number: 1)]
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in local }
            $0.chapterListLoader.load = { _ in localChapters }
            $0.bookDetailLoader.preview = { _ in
                XCTFail("已上架的书本地就有详情与目录，不该再走远端兜底")
                return nil
            }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(local)) {
            $0.detail = local
            $0.isLoading = false
            $0.isOnShelf = true
        }
        await store.receive(.chaptersLoaded(localChapters)) {
            $0.chapters = localChapters
            $0.isLoadingChapters = false
        }

        // 本地记录是唯一真相：兜底没有覆盖它，也没有多送任何动作。
        XCTAssertEqual(store.state.detail, local)
        XCTAssertEqual(store.state.chapters, localChapters)
        await store.finish()
    }
}

// MARK: - 换书 / 重复进入 / 本地读失败

// 与主 class 拆开：SwiftLint 的 `type_body_length` 按每个类型声明算。

@MainActor extension BookDetailPreviewTests {
    /// 现实里的「返回搜索结果再点另一本」：新书是新的 State，
    /// 三个加载闭包都必须按**新书的路径**取数，不能沿用上一本的。
    func test换书后按新书路径重新兜底() async {
        let otherFallback = BookDetail(bookPath: Self.otherBookPath, title: "另一本")
        let otherDetail = BookDetail(
            bookPath: Self.otherBookPath,
            title: "另一本",
            intro: "另一本的简介"
        )
        let otherChapters = [Self.makeChapter(number: 1, bookPath: Self.otherBookPath)]
        let store = TestStore(initialState: BookDetailFeature.State(fallback: otherFallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { bookPath in
                XCTAssertEqual(bookPath, Self.otherBookPath)
                return nil
            }
            $0.chapterListLoader.load = { bookPath in
                XCTAssertEqual(bookPath, Self.otherBookPath)
                return []
            }
            $0.bookDetailLoader.preview = { bookPath in
                XCTAssertEqual(bookPath, Self.otherBookPath)
                return BookPreview(detail: otherDetail, chapters: otherChapters)
            }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
            // 回退值必须是**这本书**的，不能留上一本的。
            $0.detail = otherFallback
        }
        await store.receive(.chaptersLoaded([])) {
            $0.isLoadingChapters = false
            $0.chapters = []
        }
        await store.receive(.previewLoaded(detail: otherDetail, chapters: otherChapters)) {
            $0.detail = otherDetail
            $0.chapters = otherChapters
        }

        XCTAssertEqual(store.state.detail.bookPath, Self.otherBookPath)
        XCTAssertEqual(store.state.chapters.first?.path, "/49/49035/1.html")
        await store.finish()
    }

    /// 同一本书再进一次（同一个 store）要**重新**走一遍兜底，
    /// 而且仍旧只读这本书的路径 —— 不许因为「状态里已经有数据」就跳过加载。
    func test重复进入详情仍按同一本书重新兜底() async {
        let chapters = [Self.makeChapter(number: 1)]
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { bookPath in
                XCTAssertEqual(bookPath, Self.bookPath)
                return nil
            }
            $0.chapterListLoader.load = { bookPath in
                XCTAssertEqual(bookPath, Self.bookPath)
                return []
            }
            $0.bookDetailLoader.preview = { bookPath in
                XCTAssertEqual(bookPath, Self.bookPath)
                return BookPreview(detail: Self.remoteDetail, chapters: chapters)
            }
        }

        for _ in 0 ..< 2 {
            await store.send(.onAppear) {
                $0.isLoading = true
                $0.isLoadingChapters = true
            }
            await store.receive(.hostLoaded(""))
            await store.receive(.loaded(nil)) {
                $0.isLoading = false
                $0.detail = Self.fallback
            }
            await store.receive(.chaptersLoaded([])) {
                $0.isLoadingChapters = false
                $0.chapters = []
            }
            await store.receive(.previewLoaded(detail: Self.remoteDetail, chapters: chapters)) {
                $0.detail = Self.remoteDetail
                $0.chapters = chapters
            }
        }

        XCTAssertEqual(store.state.detail, Self.remoteDetail)
        XCTAssertEqual(store.state.chapters, chapters)
        await store.finish()
    }

    /// 本地目录读失败时兜底照样把目录给出来，那条「目录加载失败」就成了过期信息。
    func test本地目录读失败时兜底补上目录并清掉过期错误() async {
        struct Failed: LocalizedError {
            var errorDescription: String? {
                "目录加载失败"
            }
        }
        let chapters = [Self.makeChapter(number: 1)]
        let store = TestStore(initialState: BookDetailFeature.State(fallback: Self.fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in nil }
            $0.chapterListLoader.load = { _ in throw Failed() }
            $0.bookDetailLoader.preview = { _ in
                BookPreview(detail: Self.remoteDetail, chapters: chapters)
            }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
            $0.isLoadingChapters = true
        }
        await store.receive(.hostLoaded(""))
        await store.receive(.loaded(nil)) {
            $0.isLoading = false
        }
        await store.receive(.chaptersFailed("目录加载失败")) {
            $0.isLoadingChapters = false
            $0.chapterErrorMessage = "目录加载失败"
        }
        await store.receive(.previewLoaded(detail: Self.remoteDetail, chapters: chapters)) {
            $0.detail = Self.remoteDetail
            $0.chapters = chapters
            $0.chapterErrorMessage = nil
        }

        XCTAssertNil(store.state.chapterErrorMessage)
        XCTAssertEqual(store.state.chapters, chapters)
        await store.finish()
    }
}
