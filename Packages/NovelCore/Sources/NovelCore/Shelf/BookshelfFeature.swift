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
            errorMessage: String? = nil
        ) {
            self.rows = rows
            self.isLoading = isLoading
            self.errorMessage = errorMessage
        }

        /// 书架行，已按「最近阅读倒序」排好（排序在 `ShelfLoaderLive` 里做）
        public var rows: [ShelfRow] = []

        /// 首次加载中。用于区分「确实是空书架」与「还没加载完」
        public var isLoading = false

        /// 加载失败原因。
        /// 🔴 `rows` 为空**不等于**空书架 —— 必须结合本字段判断，
        /// 否则加载失败会被渲染成「书架空空如也」。
        public var errorMessage: String?
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
    }

    @Dependency(\.shelfLoader) var shelfLoader

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
            }
        }
    }
}
