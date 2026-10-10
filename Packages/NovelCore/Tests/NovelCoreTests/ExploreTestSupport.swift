import Foundation
@testable import NovelCore
import NovelEngine

// 书城测试的共用夹具（`ExploreFeatureTests` / `ExplorePagingTests` / `ExploreFailureTests` 都用）。
// ⚠️ 跨文件共用 ⇒ **不能是 `private`**（`private` 只在声明它的那个文件里可见）；
// 单独放一个文件的做法照 `DownloadFeatureTestSupport.swift`。
// 里面的数据全部是**中性合成形状**，不含任何真实站点信息。

/// 合成的失败原因：只用来验证「失败文案里带上了底层原因」。
struct ExploreTestFailure: LocalizedError {
    var errorDescription: String? {
        "网络不可用。"
    }
}

/// 书城测试的共享数据。
enum ExploreTestData {
    /// `{{page}}` 是引擎要求的页码占位符。
    static let category = ExploreCategory(
        title: "示例分类",
        urlTemplate: "/catalog/1_{{page}}.html"
    )

    /// 满一页（`pageSize` 本）——用来构造「还有下一页」的初态。
    static func fullPage(_ prefix: Int) -> [Book] {
        (0 ..< ExploreFeature.pageSize).map {
            Book(path: "/book/\(prefix)_\($0)/", title: "示例书 \(prefix)-\($0)")
        }
    }
}

/// 记录书城依赖收到的调用，供测试在 `store.finish()` 后断言。
actor ExploreCallRecorder {
    private var categoriesCalls = 0
    private var booksCalls: [(title: String, page: Int)] = []
    private var savedBatches: [[ExploreCategory]] = []
    /// 还剩几次书目请求要抛错（由 `failBookCalls(_:)` 布置）。
    private var pendingBookFailures = 0

    /// 让接下来 `times` 次书目请求抛 `ExploreTestFailure`（模拟翻页时网络抖一下）。
    func failBookCalls(_ times: Int) {
        pendingBookFailures = times
    }

    func recordCategories() {
        categoriesCalls += 1
    }

    /// 记一次书目请求；若本次仍在「应失败」计数内，记完页码再抛错 ——
    /// 请求确实发出去了，所以页码照样入账（「重试请求的是哪一页」正是靠这个序列断言的）。
    func recordBooks(title: String, page: Int) throws {
        booksCalls.append((title, page))
        guard pendingBookFailures > 0 else { return }
        pendingBookFailures -= 1
        throw ExploreTestFailure()
    }

    func recordSave(_ categories: [ExploreCategory]) {
        savedBatches.append(categories)
    }

    func categoryCallCount() -> Int {
        categoriesCalls
    }

    func saveBatches() -> [[ExploreCategory]] {
        savedBatches
    }

    func bookCalls() -> [(title: String, page: Int)] {
        booksCalls
    }

    func pageNumbers() -> [Int] {
        booksCalls.map(\.page)
    }
}
