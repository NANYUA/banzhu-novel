import Foundation

/// 「某一页的第一本书」：服务端页号 + 这本书在已去重书目里的起始下标。
///
/// 页号不能由数组下标推算：整页重复时不会追加书目，但服务端页号仍可能前进。
public struct ExplorePageStart: Equatable {
    /// 服务端页号（从 1 开始）。
    public let page: Int
    /// 该页第一本新书在 `ExploreFeature.State.books` 里的下标。
    public let index: Int

    public init(page: Int, index: Int) {
        self.page = page
        self.index = index
    }
}
