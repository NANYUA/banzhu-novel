import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 目录页 reducer 测试。
@MainActor
final class ChapterListFeatureTests: XCTestCase {
    private static func makeItem(number: Int, name: String) -> ChapterItem {
        ChapterItem(
            number: number,
            name: name,
            path: "/1/1/\(number).html",
            hasLocalText: number % 2 == 0,
            isDownloaded: number == 3
        )
    }

    func test加载成功填入章节() async {
        let items = [
            Self.makeItem(number: 1, name: "第一章"),
            Self.makeItem(number: 2, name: "第二章"),
        ]
        let store = TestStore(
            initialState: ChapterListFeature.State(bookPath: "/1/1/", bookTitle: "书")
        ) {
            ChapterListFeature()
        } withDependencies: {
            $0.chapterListLoader.load = { _ in items }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded(items)) {
            $0.chapters = items
            $0.isLoading = false
        }
        await store.finish()
    }

    func test加载失败记录原因() async {
        struct LoadFailed: Error, LocalizedError {
            var errorDescription: String? {
                "目录加载失败"
            }
        }
        let store = TestStore(
            initialState: ChapterListFeature.State(bookPath: "/1/1/", bookTitle: "书")
        ) {
            ChapterListFeature()
        } withDependencies: {
            $0.chapterListLoader.load = { _ in throw LoadFailed() }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loadFailed("目录加载失败")) {
            $0.isLoading = false
            $0.errorMessage = "目录加载失败"
        }
        await store.finish()
    }

    func test加载中重复触发被忽略() async {
        let store = TestStore(
            initialState: ChapterListFeature.State(
                bookPath: "/1/1/",
                bookTitle: "书",
                isLoading: true
            )
        ) {
            ChapterListFeature()
        } withDependencies: {
            $0.chapterListLoader.load = { _ in [] }
        }

        await store.send(.onAppear)
        await store.finish()
    }
}
