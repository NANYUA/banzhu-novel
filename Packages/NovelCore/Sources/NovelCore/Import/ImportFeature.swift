import ComposableArchitecture
import Foundation

/// txt 导入流程的状态机：填信息 → 切章落盘 → 完成 / 失败。
///
/// ## 为什么要有独立 feature，而不是在 View 里直接调依赖
/// 导入是**长任务**（一本 3000 章的书要写几千个文件），中间有进度、可取消、可失败，
/// 还有「重试」这样的状态迁移。这些都属于状态，塞进 `@State` 会让视图无法测试。
/// 与 `DownloadFeature` 的理由一致：写操作要有自己的 Store。
///
/// ## 不负责什么
/// - 不负责选文件（`.fileImporter` 属于视图行为，选完把 `URL` 交给本 feature）
/// - 不负责读规则表以外的配置（书名/作者由用户在本 feature 的表单里填）
public struct ImportFeature: Reducer {
    public init() {}

    public struct State: Equatable {
        public var phase: Phase = .form
        /// 选中的文件。**生命周期比 URL 本身长**：导入过程中一直持有它。
        public var fileURL: URL
        public var title: String
        public var author: String = ""

        /// 进度文案（「正在写入第 120/3000 章…」）。`nil` = 不显示进度区。
        public var statusText: String?
        public var writtenCount: Int = 0
        public var chapterTotal: Int = 0

        /// 成功后这本书的章节数（结果页显示）。
        public var importedChapterCount: Int = 0
        public var errorMessage: String?

        /// - Parameter title: 书名初值。留空则用文件名（去扩展名）。
        public init(fileURL: URL, title: String = "") {
            self.fileURL = fileURL
            let fallbackTitle = fileURL.deletingPathExtension().lastPathComponent
            self.title = title.isEmpty ? fallbackTitle : title
        }

        public var fileName: String {
            fileURL.lastPathComponent
        }

        /// 书名不能是空白：否则书架里会出现一本叫「 」的书，且无法用书名辨认。
        public var canStart: Bool {
            phase == .form && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public var isWorking: Bool {
            phase == .working
        }
    }

    /// 导入流程的四个阶段。放 `ImportFeature` 这一层而不是塞进 `State`：
    /// SwiftLint 的 `nesting` 规则只允许类型嵌套 1 层（`State.Phase` 会到第 2 层）。
    public enum Phase: Equatable, Sendable {
        /// 填书名 / 作者，还没开始
        case form
        /// 正在跑导入管线
        case working
        case finished
        case failed
    }

    public enum Action: Equatable {
        case titleChanged(String)
        case authorChanged(String)
        case startTapped
        case progress(ImportProgress)
        case succeeded(ImportResult)
        case failed(String)
        case retryTapped
    }

    @Dependency(\.localBookImporter) var localBookImporter
    @Dependency(\.importRuleStore) var importRuleStore

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .titleChanged(value):
                state.title = value
                return .none

            case let .authorChanged(value):
                state.author = value
                return .none

            case .retryTapped:
                guard state.phase == .failed else { return .none }
                state.phase = .form
                state.errorMessage = nil
                state.statusText = nil
                return .none

            case .startTapped:
                return start(state: &state)

            case let .progress(progress):
                apply(progress, to: &state)
                return .none

            case let .succeeded(result):
                state.phase = .finished
                state.importedChapterCount = result.chapterCount
                state.chapterTotal = result.chapterCount
                state.writtenCount = result.chapterCount
                state.statusText = nil
                state.errorMessage = nil
                return .none

            case let .failed(message):
                state.phase = .failed
                state.errorMessage = message
                state.statusText = nil
                return .none
            }
        }
    }

    // MARK: - 私有

    private func start(state: inout State) -> Effect<Action> {
        guard state.canStart else { return .none }
        state.phase = .working
        state.errorMessage = nil
        state.writtenCount = 0
        state.chapterTotal = 0
        state.statusText = "正在读取文件…"

        let request = ImportRequest(
            fileURL: state.fileURL,
            title: state.title,
            author: state.author,
            rules: importRuleStore.load()
        )
        let importer = localBookImporter
        return .run { send in
            do {
                let result = try await importer.importFile(request) { progress in
                    await send(.progress(progress))
                }
                await send(.succeeded(result))
            } catch is CancellationError {
                // sheet 被关掉 ⇒ effect 被取消。这不算失败：界面随 sheet 一起消失，
                // 落盘到一半的正文已由导入器自己清理。
            } catch {
                // 用 `localizedDescription` 而非 `String(describing:)`：
                // `ImportError` / `TextDecoder.DecodingError` 都实现了 `LocalizedError`，
                // 前者给出人话，后者会打印成 `alreadyExists(title: "X")` 这种代码腔。
                await send(.failed(error.localizedDescription))
            }
        }
    }

    private func apply(_ progress: ImportProgress, to state: inout State) {
        switch progress {
        case .reading:
            state.statusText = "正在读取文件…"
        case .splitting:
            state.statusText = "正在切分章节…"
        case let .writing(done, total):
            state.writtenCount = done
            state.chapterTotal = total
            state.statusText = "正在写入第 \(done)/\(total) 章…"
        }
    }
}
