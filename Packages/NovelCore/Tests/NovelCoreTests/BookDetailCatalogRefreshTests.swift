import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

@MainActor
final class BookDetailCatalogRefreshTests: XCTestCase {
    private func item(_ number: Int, downloaded: Bool = false) -> ChapterItem {
        ChapterItem(
            number: number,
            name: "Chapter \(number)",
            path: "/42/420/\(number).html",
            hasLocalText: downloaded,
            isDownloaded: downloaded
        )
    }

    private func state() -> BookDetailFeature.State {
        var state = BookDetailFeature.State(fallback: BookDetail(bookPath: "/42/420/", title: "Book"))
        state.isOnShelf = true
        state.chapters = [item(1), item(60)]
        return state
    }

    func testRefreshReplacesIncompleteCatalogWithoutClearingDuringLoading() async {
        let complete = [item(1), item(2), item(60)]
        let store = TestStore(initialState: state()) {
            BookDetailFeature()
        } withDependencies: {
            $0.chapterCatalogRefresher.refresh = { path in
                XCTAssertEqual(path, "/42/420/")
                return complete
            }
        }
        await store.send(.refreshChapters) { $0.isRefreshingChapters = true }
        await store.receive(.chaptersRefreshed(complete)) {
            $0.isRefreshingChapters = false
            $0.chapters = complete
            $0.detail.lastChapter = "Chapter 60"
        }
        await store.finish()
    }

    func testFailureKeepsOldCatalogAndCanRetry() async {
        struct Failed: LocalizedError {
            var errorDescription: String? {
                "Request failed"
            }
        }
        let store = TestStore(initialState: state()) {
            BookDetailFeature()
        } withDependencies: {
            $0.chapterCatalogRefresher.refresh = { _ in throw Failed() }
        }
        await store.send(.refreshChapters) { $0.isRefreshingChapters = true }
        await store.receive(.chapterRefreshFailed("Request failed")) {
            $0.isRefreshingChapters = false
            $0.catalogRefreshError = "Request failed"
        }
        let complete = [item(1), item(2), item(60)]
        store.dependencies.chapterCatalogRefresher.refresh = { _ in complete }
        await store.send(.refreshChapters) {
            $0.isRefreshingChapters = true
            $0.catalogRefreshError = nil
        }
        await store.receive(.chaptersRefreshed(complete)) {
            $0.isRefreshingChapters = false
            $0.chapters = complete
            $0.detail.lastChapter = "Chapter 60"
        }
        await store.finish()
    }

    func testRepeatedRefreshIsIgnoredWhileRequestIsInFlight() async {
        var initial = state()
        initial.isRefreshingChapters = true
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        } withDependencies: {
            $0.chapterCatalogRefresher.refresh = { _ in
                XCTFail("Must not start a duplicate request")
                return []
            }
        }
        await store.send(.refreshChapters)
        await store.send(.reloadChapters)
        await store.send(.onAppear)
        await store.finish()
    }

    func testRefreshDoesNotLoseDownloadCompletionFromCurrentPage() async {
        let downloaded = item(1, downloaded: true)
        var initial = state()
        initial.chapters = [downloaded, item(60)]
        initial.isRefreshingChapters = true
        let complete = [item(1), item(2), item(60)]
        let expected = [downloaded, item(2), item(60)]
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        }
        await store.send(.chaptersRefreshed(complete)) {
            $0.isRefreshingChapters = false
            $0.chapters = expected
            $0.detail.lastChapter = "Chapter 60"
        }
        await store.finish()
    }

    func testUnshelvedBookRefreshUsesPreviewWithoutAddingToShelf() async {
        var initial = state()
        initial.isOnShelf = false
        initial.host = "https://example.com"
        let preview = BookPreview(detail: initial.detail, chapters: [item(1), item(2)])
        let store = TestStore(initialState: initial) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.preview = { _ in preview }
            $0.chapterCatalogRefresher.refresh = { _ in
                XCTFail("Unshelved preview must not update stored books")
                return []
            }
        }
        await store.send(.refreshChapters)
        await store.receive(.reloadPreview) { $0.isPreviewLoading = true }
        await store.receive(.previewLoaded(detail: preview.detail, chapters: preview.chapters)) {
            $0.isPreviewLoading = false
            $0.chapters = preview.chapters
        }
        await store.finish()
        XCTAssertFalse(store.state.isOnShelf)
    }
}

@MainActor
extension BookDetailCatalogRefreshTests {
    func testActiveReaderAdoptsMissingNextChapterWithoutMovingReadingPosition() async {
        let old = [item(1), item(2), item(60)]
        let complete = [item(1), item(2), item(3), item(60)]
        var initial = ReaderFeature.State(chapterPath: old[1].path, text: "Current chapter", currentOffset: 4, chapters: old)
        initial.pages = [PageRange(location: 0, length: 15)]
        initial.nextText = "Wrong next chapter"
        initial.nextPages = [PageRange(location: 0, length: 18)]
        initial.previousText = "Previous chapter"
        initial.previousPages = [PageRange(location: 0, length: 16)]
        let store = TestStore(initialState: initial) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = { path in
                XCTAssertEqual(path, complete[2].path)
                return "Next chapter"
            }
            $0.paginationService.paginate = { _, _ in [PageRange(location: 0, length: 12)] }
        }
        await store.send(.catalogUpdated(complete)) {
            $0.chapters = complete
            $0.nextText = ""
            $0.nextPages = []
        }
        await store.receive(.nextChapterLoaded(complete[2].path, "Next chapter")) {
            $0.nextText = "Next chapter"
            $0.nextPages = [PageRange(location: 0, length: 12)]
        }
        await store.send(.nextChapterLoaded(old[2].path, "Stale result"))
        await store.send(.catalogUpdated(complete))
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 4)
        XCTAssertEqual(store.state.text, initial.text)
        XCTAssertEqual(store.state.pages, initial.pages)
        XCTAssertEqual(store.state.previousPages, initial.previousPages)
    }

    func testDownloadStatusOnlyCatalogUpdateDoesNotReloadAdjacentChapter() async {
        let old = [item(1), item(2)]
        let updated = [item(1), item(2, downloaded: true)]
        var initial = ReaderFeature.State(chapterPath: old[0].path, text: "Current", chapters: old)
        initial.nextText = "Next"
        initial.nextPages = [PageRange(location: 0, length: 4)]
        let store = TestStore(initialState: initial) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = { _ in
                XCTFail("Status-only updates must not reload text")
                return ""
            }
        }
        await store.send(.catalogUpdated(updated)) { $0.chapters = updated }
        await store.finish()
        XCTAssertEqual(store.state.nextText, "Next")
        XCTAssertEqual(store.state.nextPages, initial.nextPages)
    }
}
