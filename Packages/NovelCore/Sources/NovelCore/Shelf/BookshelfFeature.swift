import ComposableArchitecture
import Dependencies
import Foundation

/// 书架（docs/03 §二 · §三）。
///
/// ## 这一层只管状态，不管界面
/// `check-architecture.sh` 规则 1 禁止 `Packages/` 内 `import SwiftUI`，
/// 所以 **Reducer 住 NovelCore、View 住 App**，两边靠 `StoreOf<BookshelfFeature>`
/// 的类型对接。这是那条约束第一次真正生效的地方。
///
/// ## 为什么不用 @Reducer / @ObservableState 宏
/// Xcode 16.4（macos-15 runner）下，TCA 1.23.0 的宏插件在 xcodebuild 里
/// 始终报 "produced malformed response"（两层 `-skip*Validation` 都不管用），
/// 而 `swift test`（SwiftPM）能正常跑宏。
///
/// 这个项目不能依赖「CI runner 恰好能跑宏」—— 宏在本地 Xcode 版本、
/// 未来 Xcode 升级时都可能静默失效，**正确性不能靠运行时假设担保**。
/// 手写 Reducer 协议多 3 行，换来的是「任何 Swift 编译器都能编译」。
///
/// 唯一保留的宏特性是 `@Dependency`——它是 property wrapper，不是宏，
/// 不经过编译器插件，xcodebuild 和 swift 都能正常处理。
public struct BookshelfFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(
            rows: [ShelfRow] = [],
            isLoading: Bool = false,
            errorMessage: String? = nil,
            addingCount: Int = 0,
            addNotice: String? = nil
        ) {
            self.rows = rows
            self.isLoading = isLoading
            self.errorMessage = errorMessage
            self.addingCount = addingCount
            self.addNotice = addNotice
        }

        /// 书架行，已按「最近阅读倒序」排好（排序在 `ShelfLoaderLive` 里做）
        public var rows: [ShelfRow] = []

        /// 首次加载中。用于区分「确实是空书架」与「还没加载完」
        public var isLoading = false

        /// 加载失败原因。
        /// 🔴 `rows` 为空**不等于**空书架 —— 必须结合本字段判断，
        /// 否则加载失败会被渲染成「书架空空如也」。
        public var errorMessage: String?

        /// 正在加入书架的书数（同时可能加多本）。
        /// 用计数而非布尔：并发加两本时，第一本完成不该把加载态清掉。
        public var addingCount = 0

        /// 加入书架失败/重复的提示（可关闭的横幅，不阻断列表）。
        /// 🔴 与 `errorMessage` 分开：那个是「整页加载失败」，这个是「某次操作失败」，
        /// 两者在界面上的呈现完全不同。
        public var addNotice: String?
    }

    /// 🔴 必须显式 `: Equatable`：`TestStore.receive(_:)` 活在
    /// `extension TestStore where Action: Equatable` 里 —— 不写就没法测。
    public enum Action: Equatable {
        /// 书架出现（含从后台返回）。**幂等**：已在加载中就直接忽略
        case onAppear
        /// 拉取完成
        case loaded([ShelfRow])
        /// 拉取失败
        case loadFailed(String)

        /// 请求把某本书加入书架（搜索结果点「加入书架」时发）
        case addRequested(Book)
        /// 加入成功。带 `ShelfRow` 便于直接插进列表，不用重新拉全量
        case addSucceeded(ShelfRow)
        /// 加入失败（含「已在书架里」）
        case addFailed(String)
        /// 关闭提示横幅
        case noticeDismissed
    }

    @Dependency(\.shelfLoader) var shelfLoader
    @Dependency(\.shelfAdder) var shelfAdder

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let loader = shelfLoader
                return .run { send in
                    do {
                        let rows = try await loader.load()
                        await send(.loaded(rows))
                    } catch {
                        await send(.loadFailed(String(describing: error)))
                    }
                }

            case let .loaded(rows):
                state.rows = rows
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.errorMessage = message
                state.isLoading = false
                return .none

            case let .addRequested(book):
                state.addingCount += 1
                state.addNotice = nil
                let adder = shelfAdder
                return .run { send in
                    do {
                        let row = try await adder.add(book)
                        await send(.addSucceeded(row))
                    } catch {
                        // 用 `localizedDescription` 而非 `String(describing:)`：
                        // `ShelfAdderError` 实现了 `LocalizedError`，
                        // 前者给出「《X》已经在书架里了」这种人话，
                        // 后者会打印成 `alreadyExists(title: "X")` 这种代码腔。
                        await send(.addFailed(error.localizedDescription))
                    }
                }

            case let .addSucceeded(row):
                state.addingCount = max(0, state.addingCount - 1)
                // 🔴 去重后再插：并发加同一本时可能收到两次成功
                if !state.rows.contains(where: { $0.bookPath == row.bookPath }) {
                    state.rows.insert(row, at: 0)
                }
                // 重排：新书 `lastReadAt` 为 nil 应沉底，
                // 但用户刚加完就想看到它 —— 需求是「最近阅读倒序」，
                // 从未读过的按加入时间倒序，故直接插到最前符合语义。
                return .none

            case let .addFailed(message):
                state.addingCount = max(0, state.addingCount - 1)
                state.addNotice = message
                return .none

            case .noticeDismissed:
                state.addNotice = nil
                return .none
            }
        }
    }
}
