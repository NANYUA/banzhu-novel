import ComposableArchitecture
import Dependencies
import Foundation

/// 目录页 —— 显示一本书的章节列表。
///
/// ## 数据来源
/// 加书时（`ShelfAdder`）已把目录快照存进 SwiftData，这里只读快照，不联网。
/// 所以完全离线也能显示章节列表 —— 需求「离线时显示上次已知值」的落地。
///
/// ## 点章进阅读页
/// 本 reducer 不管导航（那是 View 层的事），只负责把章节列表加载好，
/// View 拿到 `chapters` 后自行 push `ReaderView(chapterPath:)`。
public struct ChapterListFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public init(
            bookPath: String,
            bookTitle: String,
            chapters: [ChapterItem] = [],
            isLoading: Bool = false,
            errorMessage: String? = nil
        ) {
            self.bookPath = bookPath
            self.bookTitle = bookTitle
            self.chapters = chapters
            self.isLoading = isLoading
            self.errorMessage = errorMessage
        }

        /// 所属书的相对路径（如 `/49/49034/`）
        public let bookPath: String

        /// 书名（导航栏标题）
        public let bookTitle: String

        /// 章节列表（按章号升序）
        public var chapters: [ChapterItem] = []

        /// 首次加载中
        public var isLoading = false

        /// 加载失败原因
        public var errorMessage: String?
    }

    public enum Action: Equatable {
        /// 目录页出现时加载
        case onAppear
        /// 加载完成
        case loaded([ChapterItem])
        /// 加载失败
        case loadFailed(String)
    }

    @Dependency(\.chapterListLoader) var chapterListLoader

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                let loader = chapterListLoader
                let bookPath = state.bookPath
                return .run { send in
                    do {
                        let chapters = try await loader.load(bookPath)
                        await send(.loaded(chapters))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .loaded(chapters):
                state.chapters = chapters
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none
            }
        }
    }
}
