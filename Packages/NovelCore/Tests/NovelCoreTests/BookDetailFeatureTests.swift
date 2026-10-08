import ComposableArchitecture
@testable import NovelCore
import NovelEngine
import XCTest

@MainActor
final class BookDetailFeatureTests: XCTestCase {
    func test加载本地快照覆盖搜索字段() async {
        let fallback = BookDetail(book: Book(path: "/1/", title: "搜索结果"))
        let local = BookDetail(
            bookPath: "/1/",
            title: "本地书名",
            author: "本地作者",
            intro: "本地简介",
            status: "已完本",
            category: "玄幻",
            tags: ["热血"],
            wordCount: "100万字",
            lastChapter: "第 10 章",
            lastUpdated: "2026-10-09"
        )
        let store = TestStore(initialState: BookDetailFeature.State(fallback: fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in local }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded(local)) {
            $0.detail = local
            $0.isLoading = false
        }
        await store.finish()
    }

    func test本地无记录时保留搜索回退值() async {
        let fallback = BookDetail(book: Book(path: "/1/", title: "搜索结果"))
        let store = TestStore(initialState: BookDetailFeature.State(fallback: fallback)) {
            BookDetailFeature()
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loaded(fallback)) {
            $0.isLoading = false
        }
        await store.finish()
    }

    func test加载失败时保留回退值并显示错误() async {
        struct Failed: LocalizedError {
            var errorDescription: String? {
                "加载失败"
            }
        }
        let fallback = BookDetail(book: Book(path: "/1/", title: "搜索结果"))
        let store = TestStore(initialState: BookDetailFeature.State(fallback: fallback)) {
            BookDetailFeature()
        } withDependencies: {
            $0.bookDetailLoader.load = { _ in throw Failed() }
        }

        await store.send(.onAppear) {
            $0.isLoading = true
        }
        await store.receive(.loadFailed("加载失败")) {
            $0.isLoading = false
            $0.errorMessage = "加载失败"
        }
        XCTAssertEqual(store.state.detail, fallback)
        await store.finish()
    }
}
