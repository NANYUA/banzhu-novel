import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 「这本书在不在书架」+「把这本书加入书架」（依赖）。
///
/// ## 为什么需要它 —— `App` 层够不着这两件事
/// 阅读页右上「更多 → 加入书架」住在 `App` 层，而它要的两件事都锁在 `NovelCore` 里：
/// - **查重**：全仓唯一在用的「在书架」判据是详情页自己的状态
///   （`BookDetailFeature` 里 `state.isOnShelf = loaded != nil`），阅读页拿不到；
///   `NovelStore` 也**没有**「按 `bookPath` 查 `BookRecord`」的方法。
/// - **写入**：`ShelfAdder` 已是完整实现，但它是内部类型、`DependencyValues.shelfAdder`
///   也没有 `public` ⇒ 阅读页取不到。
///
/// ⇒ 把这两件事**包一层并公开**，只此一个公开面（不把 `ShelfAdder` 整体放开）。
///
/// ## ⚠️ 不另写一套写库逻辑（数据契约 ①）
/// 写入**原样转给** `ShelfAdderLive.add` —— 与详情页、搜索结果页、书架页**同一条**落库路径
/// （`BookDetailFeature` 里写着「复用 `ShelfAdder.add(_:)` 这条既有落库路径，
/// 而不是新造一条按 bookPath 加书的依赖」）。`ChapterRecord.source` 因此仍由那**唯一一处**
/// 决定，本文件**不碰** `.downloaded`。
///
/// ## 没有公开 `init`
/// 桩值走 `withDependencies { $0.shelfMembership.contains = { _ in true } }`
/// （与 `shelfAdder` 同一条路，`var` 是公开的）⇒ 不必从模块外构造整个值。
public struct ShelfMembership: Sendable {
    /// 这本书是否**已经有 `BookRecord`**（= 已在书架）。入参是 `bookPath`。
    public var contains: @Sendable (String) async -> Bool

    /// 加入书架。入参原样交给 `ShelfAdderLive.add`。
    ///
    /// - Returns: 「操作后这本书在不在书架」：`true` = 本次加入成功、或**本来就在**；
    ///   `false` = 网络 / 盾 / 存储失败（**没落库**）。
    ///   刻意**不抛错**：阅读页没有位置弹错误框（既有风格是安静降级），
    ///   失败时菜单项维持「加入书架」，用户再点一次即可。
    public var add: @Sendable (Book) async -> Bool
}

extension DependencyValues {
    /// 「这本书在不在书架 / 把它加入书架」。测试里用
    /// `withDependencies { $0.shelfMembership.add = { _ in true } }` 替换。
    public var shelfMembership: ShelfMembership {
        get { self[ShelfMembershipKey.self] }
        set { self[ShelfMembershipKey.self] = newValue }
    }

    private enum ShelfMembershipKey: DependencyKey {
        static let liveValue = ShelfMembership(
            contains: { await ShelfMembershipLive.contains(bookPath: $0) },
            add: { await ShelfMembershipLive.add($0) }
        )

        /// 测试默认值：一律 `false`（**读安静、写不假装成功** —— 与 `ShelfAdder` 的
        /// `testValue` 同一条口径：忘了注入桩就不该出现「已在书架」或「加成功了」）。
        static let testValue = ShelfMembership(
            contains: { _ in false },
            add: { _ in false }
        )
    }
}

/// 真实实现：查重走 SwiftData，写入原样交给 `ShelfAdderLive`。
@MainActor
private enum ShelfMembershipLive {
    /// 库里有没有这本书的 `BookRecord`。
    ///
    /// 判据与 `ShelfAdderLive.add` 的查重**逐字一致**（同一个 `#Predicate`、
    /// 同样 `fetchLimit = 1`）⇒「菜单项显示已在书架」与「加入时会不会撞 `alreadyExists`」
    /// 是同一个真相，不会出现「显示可点、点下去说已存在」。
    static func contains(bookPath: String) -> Bool {
        guard let context = try? ModelContext(NovelStore.makeContainer()) else { return false }
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first) != nil
    }

    /// 加入书架。
    static func add(_ book: Book) async -> Bool {
        do {
            _ = try await ShelfAdderLive.add(book)
            return true
        } catch let error as ShelfAdderError {
            // 逐 case 匹配（不用 `catch is ShelfAdderError`）：`ShelfAdderError` 现在只有
            // `alreadyExists` 一个 case ⇒ 命中它就是「本来就在书架」，目标状态已经成立，
            // 按成功处理（调用方据此显示「已在书架」）。⚠️ 将来若新增 case，这里会**编译不过**，
            // 逼着重新判断 —— 比默默按成功处理安全。
            switch error {
            case .alreadyExists:
                return true
            }
        } catch {
            // 网络 / 盾 / 存储失败 ⇒ 没落库，报 `false`（菜单项维持原样，可重试）。
            return false
        }
    }
}
