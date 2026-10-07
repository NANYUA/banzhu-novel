import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 阅读页 reducer 测试。
///
/// 用 `FakeMeasuring`（宽预算 10，中文 2 宽 → 每页约 5 字）确定性分页，
/// 钉住翻页和 characterOffset 数据契约。
@MainActor
final class ReaderFeatureTests: XCTestCase {
    private func makeStore(
        text: String,
        loader: @escaping @Sendable (String) async throws -> String
    ) -> TestStore<ReaderFeature.State, ReaderFeature.Action> {
        TestStore(initialState: ReaderFeature.State(chapterPath: "/1/1.html")) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = loader
            $0.paginationService.paginate = { text, config in
                Paginator(measurer: FakeMeasuring(widthBudget: 10))
                    .paginate(text: text, configuration: config)
            }
        }
    }

    /// 每页 5 个中文：10 字 = 2 页，每页 range 正确
    func test加载后分页正确() async {
        let store = makeStore(text: "一二三四五六七八九十") { _ in "一二三四五六七八九十" }

        await store.send(.loadChapter("/1/1.html")) {
            $0.chapterPath = "/1/1.html"
            $0.isLoading = true
            $0.text = ""
            $0.pages = []
            $0.currentOffset = 0
        }
        await store.receive(.contentLoaded("一二三四五六七八九十")) {
            $0.text = "一二三四五六七八九十"
            $0.isLoading = false
            // 10 字，每页 5 字 → 2 页：page0 = {0,5}, page1 = {5,5}
            $0.pages = [
                PageRange(location: 0, length: 5),
                PageRange(location: 5, length: 5),
            ]
            $0.currentOffset = 0
        }
        await store.finish()
    }

    /// 下一页：offset 从 0 → 5（第二页起点）
    func test下一页移动offset() async {
        let store = makeStore(text: "一二三四五六七八九十") { _ in "一二三四五六七八九十" }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded("一二三四五六七八九十"))

        await store.send(.nextPage) {
            $0.currentOffset = 5
        }
        await store.finish()
    }

    /// 上一页：从第二页回到第一页
    func test上一页移动offset() async {
        let store = makeStore(text: "一二三四五六七八九十") { _ in "一二三四五六七八九十" }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded("一二三四五六七八九十"))
        await store.send(.nextPage) { $0.currentOffset = 5 }

        await store.send(.prevPage) {
            $0.currentOffset = 0
        }
        await store.finish()
    }

    /// 最后一页再下一页：不越界
    func test最后一页下一页不动() async {
        let store = makeStore(text: "一二三四五六七八九十") { _ in "一二三四五六七八九十" }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded("一二三四五六七八九十"))
        await store.send(.nextPage) { $0.currentOffset = 5 }

        // 已在最后一页（第 2 页），再下一页无变化
        await store.send(.nextPage)
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 5)
    }

    /// 第一页上一页：不动
    func test第一页上一页不动() async {
        let store = makeStore(text: "一二三四五六七八九十") { _ in "一二三四五六七八九十" }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded("一二三四五六七八九十"))

        await store.send(.prevPage)
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 0)
    }

    /// jumpToOffset：跳到一个位置，随后 nextPage 从那里继续
    func test跳转到指定offset() async {
        let store = makeStore(text: "一二三四五六七八九十") { _ in "一二三四五六七八九十" }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded("一二三四五六七八九十"))

        await store.send(.jumpToOffset(3)) {
            $0.currentOffset = 3
        }
        // offset=3 在第 0 页（0..<5），next 去第 1 页（5）
        await store.send(.nextPage) {
            $0.currentOffset = 5
        }
        await store.finish()
    }

    /// jumpToOffset 越界 clamp
    func test跳转越界clamp() async {
        let store = makeStore(text: "一二三四五六七八九十") { _ in "一二三四五六七八九十" }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded("一二三四五六七八九十"))

        await store.send(.jumpToOffset(999)) {
            $0.currentOffset = 10 // 文本 10 字符，clamp 到 10
        }
        await store.finish()
    }

    /// 🔴 数据契约：改配置重新分页，但 currentOffset 不丢
    func test改配置重新分页且offset不丢() async {
        // 文本 10 字。宽预算 10 → 每页 5 字 → 2 页。
        // 读到第 2 页（offset=5），然后改配置为宽预算 5 → 每页 2~3 字 → 页数变多。
        // 关键断言：currentOffset 仍是 5（不因重新分页跳走）。
        let store = TestStore(initialState: ReaderFeature.State(chapterPath: "/1/1.html")) {
            ReaderFeature()
        } withDependencies: {
            $0.readerLoader.load = { _ in "一二三四五六七八九十" }
            $0.paginationService.paginate = { text, _ in
                Paginator(measurer: FakeMeasuring(widthBudget: 10))
                    .paginate(text: text, configuration: PaginationConfiguration(containerSize: CGSize(width: 320, height: 480)))
            }
        }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded("一二三四五六七八九十"))
        await store.send(.nextPage) { $0.currentOffset = 5 }

        // 改配置（容器尺寸变 → 重新分页）
        await store.send(.configChanged(PaginationConfiguration(
            containerSize: CGSize(width: 400, height: 480)
        )))
        await store.finish()
        XCTAssertEqual(store.state.currentOffset, 5, "改配置后 offset 不应丢")
    }

    /// 加载失败：errorMessage 记录，isLoading 结束
    func test加载失败() async {
        struct LoadErr: Error, LocalizedError {
            var errorDescription: String? { "网络错误" }
        }
        let store = makeStore(text: "") { _ in throw LoadErr() }

        await store.send(.loadChapter("/1/1.html")) {
            $0.chapterPath = "/1/1.html"
            $0.isLoading = true
        }
        await store.receive(.loadFailed("网络错误")) {
            $0.isLoading = false
            $0.errorMessage = "网络错误"
        }
        await store.finish()
    }

    /// 空文本：pages 空，翻页无效果
    func test空文本() async {
        let store = makeStore(text: "") { _ in "" }
        await store.send(.loadChapter("/1/1.html"))
        await store.receive(.contentLoaded(""))

        await store.send(.nextPage)
        await store.send(.prevPage)
        await store.finish()
        XCTAssertTrue(store.state.pages.isEmpty)
        XCTAssertEqual(store.state.currentOffset, 0)
    }
}
