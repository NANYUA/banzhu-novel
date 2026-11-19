import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

final class ReaderTextRenderingTests: XCTestCase {
    private let configuration = PaginationConfiguration(containerSize: CGSize(width: 320, height: 480))
    private let content = ReaderPageContent(text: "甲乙丙丁", page: PageRange(location: 0, length: 2))

    func testRepeatedUpdatesDoNotRequestTextRendering() {
        var cache = ReaderTextRenderCache()
        XCTAssertTrue(cache.update(content: content, configuration: configuration))
        for _ in 0 ..< 180 {
            let sameContent = ReaderPageContent(text: "甲乙丙丁", page: PageRange(location: 0, length: 2))
            XCTAssertFalse(cache.update(content: sameContent, configuration: configuration))
        }
        XCTAssertEqual(cache.slice.text, "甲乙")
        XCTAssertTrue(cache.slice.startsAtParagraphStart)
    }

    func testContentAndTitleChangesInvalidateSamePageRange() {
        var cache = ReaderTextRenderCache()
        XCTAssertTrue(cache.update(content: content, configuration: configuration))
        let replacement = ReaderPageContent(text: "戊己庚辛", page: content.page)
        XCTAssertTrue(cache.update(content: replacement, configuration: configuration))
        XCTAssertEqual(cache.slice.text, "戊己")
        let titled = ReaderPageContent(text: replacement.text, chapterName: "新章", page: content.page)
        XCTAssertTrue(cache.update(content: titled, configuration: configuration))
        XCTAssertEqual(cache.slice.text, "新章")
    }

    func testSameVisibleTextStillInvalidatesParagraphBoundary() {
        var cache = ReaderTextRenderCache()
        let first = ReaderPageContent(text: "甲甲\n甲甲", page: PageRange(location: 0, length: 1))
        let continuation = ReaderPageContent(text: first.text, page: PageRange(location: 1, length: 1))
        let nextParagraph = ReaderPageContent(text: first.text, page: PageRange(location: 3, length: 1))
        XCTAssertTrue(cache.update(content: first, configuration: configuration))
        XCTAssertTrue(cache.slice.startsAtParagraphStart)
        XCTAssertTrue(cache.update(content: continuation, configuration: configuration))
        XCTAssertEqual(cache.slice.text, "甲")
        XCTAssertFalse(cache.slice.startsAtParagraphStart)
        XCTAssertTrue(cache.update(content: nextParagraph, configuration: configuration))
        XCTAssertTrue(cache.slice.startsAtParagraphStart)
    }

    func testFallbackUsesExactlyThePaginationNormalization() {
        let raw = "　甲乙\n  丙丁\n\n"
        let input = ReaderPageContent(text: raw, chapterName: "  章名  ")
        XCTAssertEqual(input.renderedSlice.text, "章名\n\n甲乙\n丙丁")
        XCTAssertEqual(
            input.renderedSlice.text,
            ReaderFeature.State.displayText(chapterName: input.chapterName, text: raw)
        )
        XCTAssertTrue(input.renderedSlice.startsAtParagraphStart)
        let existingTitle = ReaderPageContent(text: "章名\n甲乙", chapterName: "章名")
        XCTAssertEqual(existingTitle.renderedSlice.text, "章名\n甲乙")
    }

    func testUnicodeSlicesConserveCharactersAndParagraphBoundaries() {
        let raw = "甲👨‍👩‍👧‍👦e\u{301}𠮷乙\n丙\r\n丁"
        let source = ReaderPageContent(text: raw).renderedSlice.text
        let chars = Array(source)
        let slices = chars.indices.map { index in
            ReaderPageContent(text: raw, page: PageRange(location: index, length: 1)).renderedSlice
        }
        XCTAssertEqual(slices.map(\.text).joined(), source)
        for (index, slice) in slices.enumerated() {
            XCTAssertEqual(slice.text.count, 1)
            XCTAssertEqual(slice.startsAtParagraphStart, ParagraphBoundary.isParagraphStart(chars, at: index))
        }
        XCTAssertGreaterThan(slices[1].text.utf16.count, slices[1].text.count)
        XCTAssertEqual(ParagraphBoundary.firstParagraphUTF16Length(in: "👨‍👩‍👧‍👦\r\n甲"), 13)
    }

    func testEmptyAndOutOfBoundsPagesAreSafe() {
        let ranges = [
            PageRange(location: -1, length: 2),
            PageRange(location: 2, length: 1),
            PageRange(location: Int.max, length: 1),
            PageRange(location: 0, length: 0),
            PageRange(location: 0, length: -1),
        ]
        for range in ranges {
            let slice = ReaderPageContent(text: "甲乙", page: range).renderedSlice
            XCTAssertEqual(slice.text, "")
            XCTAssertTrue(slice.startsAtParagraphStart)
        }
        XCTAssertEqual(ReaderPageContent(text: "").renderedSlice.text, "")
        let longRange = ReaderPageContent(text: "甲乙", page: PageRange(location: 1, length: Int.max))
        XCTAssertEqual(longRange.renderedSlice.text, "乙")
    }

    func testReflowChangesRangeWithoutLosingCharacterPosition() {
        var cache = ReaderTextRenderCache()
        let before = ReaderPageContent(text: "甲乙丙丁戊己", page: PageRange(location: 2, length: 2))
        XCTAssertTrue(cache.update(content: before, configuration: configuration))
        var rotated = configuration
        rotated.containerSize = CGSize(width: 480, height: 320)
        let after = ReaderPageContent(text: before.text, page: PageRange(location: 0, length: 4))
        XCTAssertTrue(cache.update(content: after, configuration: rotated))
        XCTAssertEqual(cache.slice.text, "甲乙丙丁")
        XCTAssertTrue(cache.slice.text.contains("丙"))
        XCTAssertFalse(cache.update(content: after, configuration: rotated))
    }

    func testAllTextAndLayoutSettingsInvalidate() {
        let changes: [(inout PaginationConfiguration) -> Void] = [
            { $0.containerSize.width += 1 },
            { $0.containerSize.height += 1 },
            { $0.fontSize += 1 },
            { $0.fontName = "TestFont" },
            { $0.lineSpacing += 1 },
            { $0.paragraphSpacing += 1 },
            { $0.characterSpacing += 1 },
            { $0.isBold.toggle() },
            { $0.isItalic.toggle() },
            { $0.isFirstLineIndentOn.toggle() },
            { $0.inset.top += 1 },
            { $0.inset.bottom += 1 },
            { $0.inset.leading += 1 },
            { $0.inset.trailing += 1 },
            { $0.backgroundStyle = .black },
            { $0.customBackgroundColor.red += 0.01 },
            { $0.customBackgroundColorDark.red += 0.01 },
            { $0.textColorMode = .custom },
            { $0.customTextColor.red += 0.01 },
        ]
        assertChanges(changes, invalidate: true)
    }

    func testUnrelatedControlsAndDynamicAppearanceDoNotResetText() {
        let changes: [(inout PaginationConfiguration) -> Void] = [
            { $0.hudHorizontalInset += 1 },
            { $0.topBarInset = 10 },
            { $0.bottomBarInset += 1 },
            { $0.showsTextAreaBorder.toggle() },
            { $0.followsSystemBrightness.toggle() },
            { $0.appearanceMode = .dark },
        ]
        assertChanges(changes, invalidate: false)
    }

    private func assertChanges(_ changes: [(inout PaginationConfiguration) -> Void], invalidate: Bool) {
        for (index, change) in changes.enumerated() {
            var cache = ReaderTextRenderCache()
            XCTAssertTrue(cache.update(content: content, configuration: configuration))
            let originalSlice = cache.slice
            var modified = configuration
            change(&modified)
            XCTAssertEqual(cache.update(content: content, configuration: modified), invalidate, "setting \(index)")
            XCTAssertEqual(cache.slice, originalSlice)
            XCTAssertFalse(cache.update(content: content, configuration: modified))
        }
    }
}

@MainActor extension ReaderTextRenderingTests {
    func testTurningAndUnrelatedSettingsNeverCallPaginator() async {
        var initial = ReaderFeature.State(chapterPath: "/reading-test", text: "甲乙丙丁")
        initial.pages = [PageRange(location: 0, length: 2), PageRange(location: 2, length: 2)]
        let calls = LockIsolated(0)
        let store = TestStore(initialState: initial) {
            ReaderFeature()
        } withDependencies: {
            $0.paginationService.paginate = { _, _ in
                calls.withValue { $0 += 1 }
                return []
            }
            $0.readingProgressStore.markRead = { _, _, _ in }
            $0.readingSettingsStore.save = { _ in }
        }
        await store.send(.nextPage) { $0.currentOffset = 2 }
        await store.send(.prevPage) { $0.currentOffset = 0 }
        await store.send(.goToPage(1)) { $0.currentOffset = 2 }
        await store.send(.pageJumpCommitted)
        await store.send(.containerSizeChanged(initial.config.containerSize))
        var controls = initial.config
        controls.showsTextAreaBorder.toggle()
        controls.topBarInset = 10
        await store.send(.configChanged(controls)) { $0.config = controls }
        await store.finish()
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(store.state.pages, initial.pages)
        XCTAssertEqual(store.state.currentOffset, 2)
    }

    func testRotationRepaginatesOnceAndRetainsCharacterOffset() async {
        var initial = ReaderFeature.State(chapterPath: "/reading-test", text: "甲乙丙丁", currentOffset: 2)
        initial.pages = [PageRange(location: 0, length: 2), PageRange(location: 2, length: 2)]
        let calls = LockIsolated(0)
        let store = TestStore(initialState: initial) {
            ReaderFeature()
        } withDependencies: {
            $0.paginationService.paginate = { _, _ in
                calls.withValue { $0 += 1 }
                return [PageRange(location: 0, length: 4)]
            }
        }
        let rotated = CGSize(width: 480, height: 320)
        await store.send(.containerSizeChanged(rotated)) {
            $0.config.containerSize = rotated
            $0.pages = [PageRange(location: 0, length: 4)]
        }
        await store.send(.containerSizeChanged(rotated))
        await store.finish()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(store.state.currentOffset, 2)
        XCTAssertEqual(store.state.currentPageIndex, 0)
    }
}

@MainActor
final class ReaderPageIndexTests: XCTestCase {
    func testBinaryLookupPageStartsMiddleAndEndBoundaries() {
        let pages = [
            PageRange(location: 0, length: 4),
            PageRange(location: 4, length: 3),
            PageRange(location: 7, length: 2),
        ]
        var state = ReaderFeature.State(chapterPath: "/reading", text: "abcdefghi")
        state.pages = pages
        let cases: [(Int, Int?)] = [
            (0, 0), (3, 0), (4, 1), (6, 1), (7, 2), (8, 2),
            (-1, nil), (9, nil), (Int.max, nil),
        ]
        for (offset, expected) in cases {
            XCTAssertEqual(state.pageIndex(containing: offset), expected, "offset \(offset)")
        }
        XCTAssertEqual(state.currentPageIndex, 0)
        state.currentOffset = Int.max
        XCTAssertEqual(state.currentPageIndex, 2, "异常 offset 保持原有末页兜底语义")
        state.pages = []
        XCTAssertEqual(state.currentPageIndex, -1)
    }
}
