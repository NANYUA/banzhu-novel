import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine

/// 下载速率档位。
///
/// 两档都是串行（一次只下一章），区别只在请求之间是否加入人工间隔。
/// 默认保守档，避免批量下载时撞上站方防护。
public enum DownloadSpeed: String, CaseIterable, Equatable, Sendable {
    /// 保守档：串行 + 请求间隔（默认）
    case conservative
    /// 快速档：串行 + 无间隔
    case fast
}

/// 下载失败的来源分类。
public enum DownloadFailureSource: Equatable, Sendable {
    /// 遇到人机验证（盾）。
    case guardRequired
    /// 服务器明确拒绝（如 403）。
    case forbidden
    /// 普通网络失败（抖动、超时、解码失败等）。
    case other
}

/// 已分类的下载失败。
///
/// 分类只做一次，避免把 `NetworkError` 的分支判断散落在 reducer 的多处。
public struct DownloadFailure: Error, Equatable, LocalizedError, Sendable {
    public init(source: DownloadFailureSource, message: String) {
        self.source = source
        self.message = message
    }

    public let source: DownloadFailureSource
    public let message: String

    public var errorDescription: String? {
        message
    }
}

/// 把网络层抛出的错误翻成下载队列能处理的类别。
func classifyDownloadFailure(_ error: any Error) -> DownloadFailure {
    guard let networkError = error as? NetworkError else {
        return DownloadFailure(source: .other, message: error.localizedDescription)
    }
    switch networkError {
    case .guarded:
        return DownloadFailure(source: .guardRequired, message: networkError.localizedDescription)
    case .httpStatus(403):
        return DownloadFailure(source: .forbidden, message: networkError.localizedDescription)
    case .httpStatus, .badResponse, .decodeFailed, .transport:
        return DownloadFailure(source: .other, message: networkError.localizedDescription)
    }
}

/// 下载队列执行器。
///
/// ## 为什么是串行
/// 需求明确：保守档与快速档都是「一次一章」，只有间隔不同。
/// 这里不引入并发，避免批量下载对站方造成突发压力。
///
/// ## 为什么状态是快照
/// SwiftData 的 `@Model` 不是 `Sendable`，不能跨 Effect 边界。
/// reducer 只持有 `DownloadTaskSnapshot`，真正的持久化模型留在存储依赖里。
///
/// ## 预检与暂停
/// 每次开始下一章前先把该章标记为 `downloading`，再让 Effect 发请求；
/// 这样 App 被杀后重启，队列不会漏掉任何一项。
///
/// ## 为什么不用 `@Reducer` 宏
/// 同其它 Feature：CI 的宏校验不可用，手写 `Reducer` 协议，
/// 只保留 `@Dependency`（property wrapper，非宏）。
public struct DownloadFeature: Reducer {
    public init() {}

    public enum Action: Equatable {
        /// 队列页出现时加载持久化任务。
        case task
        /// 载入完成。
        case loaded([DownloadTaskSnapshot])
        /// 入队一批章节（单章 / 整本 / 书架批量都走这里）。
        case enqueue([DownloadChapterRequest])
        /// 入队完成，带回完整队列。
        case enqueued([DownloadTaskSnapshot])
        /// 全局暂停。
        case pauseAll
        /// 全局继续。
        case resumeAll
        /// 暂停单本。
        case pauseBook(String)
        /// 取消单本（删除该书全部任务）。
        case cancelBook(String)
        /// 开关 WiFi 门控。
        case setAllowsCellular(Bool)
        /// 切换速率档位。
        case setSpeed(DownloadSpeed)
        /// 只重试失败的任务。
        case retryFailed
        /// 用户处理完验证后，重试被拦截的任务。
        case retryBlocked
        /// 重新读取持久化队列（跨重启 / 外部变更后）。
        case reload
        /// 手动踢一脚调度（App 回到前台等）。
        case next
        /// 正文已下载成功。
        case downloaderSucceeded(String, String)
        /// 正文下载失败。
        case downloaderFailed(String, DownloadFailure)
        /// 状态变更已持久化，带回完整队列。
        case persisted([DownloadTaskSnapshot])
        /// 持久化失败。
        case storeFailed(String)
        /// 关闭横幅。
        case noticeDismissed
    }

    @Dependency(\.downloadQueueStore) var queue
    @Dependency(\.chapterDownloader) var downloader

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task, .reload:
                let store = queue
                return .run { send in
                    do {
                        try await send(.loaded(store.load()))
                    } catch {
                        await send(.storeFailed(error.localizedDescription))
                    }
                }

            case let .loaded(tasks):
                state.tasks = normalize(tasks)
                return startNextTask(state: &state, queue: queue, downloader: downloader)

            case let .enqueue(requests):
                guard !requests.isEmpty else { return .none }
                state.notice = nil
                let store = queue
                return .run { send in
                    do {
                        try await send(.enqueued(store.enqueue(requests)))
                    } catch {
                        await send(.storeFailed(error.localizedDescription))
                    }
                }

            case let .enqueued(tasks):
                state.tasks = tasks
                if !state.hasAutoWork, state.failedCount == 0 {
                    state.notice = "没有新增下载任务。"
                }
                return startNextTask(state: &state, queue: queue, downloader: downloader)

            case .pauseAll:
                state.isPaused = true
                state.notice = "已暂停全部下载。"
                let ids = state.tasks.filter(\.state.isActive).map(\.id)
                guard !ids.isEmpty else { return .none }
                markPausedLocally(&state.tasks) { $0.state.isActive }
                return persist(mutation: .pauseByUser, ids: ids, with: queue)

            case .resumeAll:
                state.isPaused = false
                state.notice = nil
                let ids = state.tasks
                    .filter { $0.state == .paused && !$0.blockedByGuard }
                    .map(\.id)
                guard !ids.isEmpty else {
                    return startNextTask(state: &state, queue: queue, downloader: downloader)
                }
                return persist(mutation: .requeue, ids: ids, with: queue)

            case let .pauseBook(bookPath):
                let ids = state.tasks
                    .filter { $0.bookPath == bookPath && $0.state.isActive }
                    .map(\.id)
                guard !ids.isEmpty else { return .none }
                state.notice = "已暂停《\(bookTitle(in: state, bookPath: bookPath))》的下载。"
                markPausedLocally(&state.tasks) {
                    $0.bookPath == bookPath && $0.state.isActive
                }
                return persist(mutation: .pauseByUser, ids: ids, with: queue)

            case let .cancelBook(bookPath):
                let ids = state.tasks.filter { $0.bookPath == bookPath }.map(\.id)
                guard !ids.isEmpty else { return .none }
                state.notice = "已取消《\(bookTitle(in: state, bookPath: bookPath))》的下载。"
                // 本地先移除：正在飞的那一项结果回来时找不到任务，会被当作作废结果丢弃。
                // 但**不要**在这里清 `isDownloading` —— 旧请求可能还没结束，
                // 提前放行会让调度器并发开第二个请求。
                state.tasks.removeAll { $0.bookPath == bookPath }
                let store = queue
                return .run { send in
                    do {
                        try await store.remove(ids)
                        await send(.reload)
                    } catch {
                        await send(.storeFailed(error.localizedDescription))
                    }
                }

            case let .setAllowsCellular(enabled):
                state.allowsCellular = enabled
                if enabled == false, state.currentTask != nil || state.queuedCount > 0 {
                    state.notice = "当前仅在 WiFi 下下载。"
                }
                return startNextTask(state: &state, queue: queue, downloader: downloader)

            case let .setSpeed(speed):
                state.speed = speed
                return .none

            case .retryFailed:
                let ids = state.tasks.filter { $0.state == .failed }.map(\.id)
                guard !ids.isEmpty else { return .none }
                state.notice = nil
                return persist(mutation: .requeue, ids: ids, with: queue)

            case .retryBlocked:
                let ids = state.tasks.filter(\.blockedByGuard).map(\.id)
                guard !ids.isEmpty else { return .none }
                // 用户处理完验证／等待冷却后主动重试：必须同时解除全局暂停，
                // 否则任务只是重新排队，却永远不会被调度器拾起。
                state.isPaused = false
                state.notice = nil
                return persist(mutation: .requeue, ids: ids, with: queue)

            case let .persisted(tasks):
                state.tasks = tasks
                return startNextTask(state: &state, queue: queue, downloader: downloader)

            case .next:
                return startNextTask(state: &state, queue: queue, downloader: downloader)

            case let .downloaderSucceeded(taskID, text):
                state.isDownloading = false
                // 下载期间用户暂停 / 取消：该任务已不是 `downloading`。
                // 丢弃这次结果 —— 不写「已完成」也不落盘，恢复后会重新下载该章。
                // 只认任务自身状态，不看全局开关：单本暂停时全局开关并没有被按下。
                guard isInFlight(state, taskID) else {
                    return startNextTask(state: &state, queue: queue, downloader: downloader)
                }
                let store = queue
                return .run { send in
                    do {
                        _ = try await store.complete(taskID, text)
                        await send(.reload)
                    } catch {
                        await send(.storeFailed(error.localizedDescription))
                    }
                }

            case let .downloaderFailed(taskID, failure):
                state.isDownloading = false
                // 同上：任务已被暂停 / 取消时，这次失败不再归类，
                // 否则会凭空多出一条「失败」记录。
                guard isInFlight(state, taskID) else {
                    return startNextTask(state: &state, queue: queue, downloader: downloader)
                }
                let message = failure.message
                let store = queue

                switch failure.source {
                case .guardRequired, .forbidden:
                    state.isPaused = true
                    state.notice = failure.source == .forbidden
                        ? "服务器拒绝了请求，已暂停下载。请稍后再继续。"
                        : "需要人机验证，已暂停下载。"
                    return .run { send in
                        do {
                            try await send(.persisted(store.mutate([taskID], .pauseBlocked(message))))
                        } catch {
                            await send(.storeFailed(error.localizedDescription))
                        }
                    }

                case .other:
                    state.notice = "下载失败：\(message)"
                    return persist(mutation: .markFailed(message), ids: [taskID], with: queue)
                }

            case let .storeFailed(message):
                state.isDownloading = false
                // 标记「下载中」这一步若失败，本地不能停留在 downloading，
                // 否则调度器只挑 queued，会把这个任务永久跳过。
                for index in state.tasks.indices where state.tasks[index].state == .downloading {
                    state.tasks[index].state = .queued
                }
                state.notice = message
                return .none

            case .noticeDismissed:
                state.notice = nil
                return .none
            }
        }
    }
}

// MARK: - 状态

/// 队列状态与 reducer body 分开声明，避免单个类型体量超过 SwiftLint 上限。
public extension DownloadFeature {
    struct State: Equatable {
        public init(
            tasks: [DownloadTaskSnapshot] = [],
            isPaused: Bool = false,
            allowsCellular: Bool = false,
            speed: DownloadSpeed = .conservative,
            isDownloading: Bool = false,
            notice: String? = nil
        ) {
            self.tasks = tasks
            self.isPaused = isPaused
            self.allowsCellular = allowsCellular
            self.speed = speed
            self.isDownloading = isDownloading
            self.notice = notice
        }

        /// 持久化任务的只读投影，按入队顺序排列。
        public var tasks: [DownloadTaskSnapshot] = []

        /// 全局暂停开关。
        public var isPaused = false

        /// 是否允许蜂窝网络启动下载；默认只允许 WiFi。
        public var allowsCellular = false

        /// 速率档位；默认保守档。
        public var speed: DownloadSpeed = .conservative

        /// 当前是否有下载 Effect 在跑。
        public var isDownloading = false

        /// 面向用户的横幅提示。
        public var notice: String?

        /// 是否有自动化任务在等待（不含用户手动暂停的项）。
        public var hasAutoWork: Bool {
            tasks.contains { $0.state == .queued || $0.state == .downloading }
        }

        /// 待处理任务数（排队 + 进行中）。
        public var queuedCount: Int {
            tasks.filter(\.state.isActive).count
        }

        /// 已完成任务数。
        public var finishedCount: Int {
            tasks.filter(\.state.isFinished).count
        }

        /// 失败任务数。
        public var failedCount: Int {
            tasks.filter { $0.state == .failed }.count
        }

        /// 因验证或 403 自动暂停的任务数。
        public var blockedCount: Int {
            tasks.filter(\.blockedByGuard).count
        }

        /// 当前正在下载的任务。
        public var currentTask: DownloadTaskSnapshot? {
            tasks.first { $0.state == .downloading }
        }

        /// 进度百分比：`done / total`。
        ///
        /// 空队列返回 0；`done` 只计算真正完成的章节，
        /// 失败与暂停仍占总量，避免进度看起来「完成」了却没下完。
        public var progress: Double {
            guard !tasks.isEmpty else { return 0 }
            return Double(finishedCount) / Double(tasks.count)
        }
    }
}

// MARK: - 调度辅助

/// 是否允许启动下一章：未暂停、允许当前网络、且没有在跑的下载。
private func shouldRun(_ state: DownloadFeature.State) -> Bool {
    !state.isPaused && state.allowsCellular && !state.isDownloading
}

/// 把重启后残留的「下载中」任务恢复为「排队中」。
///
/// App 在下载过程中被杀时，数据库里会留下 `downloading` 的僵尸任务；
/// 调度器只挑 `queued`，若不恢复会让整个队列永久卡住。
private func normalize(_ tasks: [DownloadTaskSnapshot]) -> [DownloadTaskSnapshot] {
    tasks.map { task in
        guard task.state == .downloading else { return task }
        var revived = task
        revived.state = .queued
        revived.finishedAt = nil
        return revived
    }
}

/// 本地立刻把匹配的任务标成「用户暂停」。
///
/// 已经发出去的请求没法真正取消，所以状态必须**在本地先改**：
/// 结果回来时只认「这个任务还是不是 `downloading`」，而不是看全局暂停开关。
/// 否则「暂停单本」之后，那一章的正文照样会被写成「已完成」。
private func markPausedLocally(
    _ tasks: inout [DownloadTaskSnapshot],
    where shouldPause: (DownloadTaskSnapshot) -> Bool
) {
    for index in tasks.indices where shouldPause(tasks[index]) {
        tasks[index].state = .paused
        tasks[index].blockedByGuard = false
        tasks[index].lastError = nil
    }
}

/// 该任务此刻是否仍是「正在跑」的那一项。
///
/// 用户中途暂停 / 取消会把它改成 `paused` 或直接移出队列，
/// 这时结果必须丢弃，不能拿来改状态。
private func isInFlight(_ state: DownloadFeature.State, _ taskID: String) -> Bool {
    state.tasks.first { $0.id == taskID }?.state == .downloading
}

/// 启动队列里的下一章（若有）。
///
/// 调度内联而不是发一个 `.next` 自环动作：后者会让一次状态迁移多一次
/// Effect 往返，测试也更难对齐。`.next` 动作保留给外部手动触发。
private func startNextTask(
    state: inout DownloadFeature.State,
    queue: DownloadQueueStore,
    downloader: ChapterDownloader
) -> Effect<DownloadFeature.Action> {
    guard shouldRun(state) else { return .none }
    guard let index = state.tasks.firstIndex(where: { $0.state == .queued }) else {
        return .none
    }

    state.tasks[index].state = .downloading
    state.isDownloading = true
    let task = state.tasks[index]
    let waitNanoseconds = delayNanoseconds(for: state.speed)

    return .run { send in
        do {
            _ = try await queue.mutate([task.id], .markDownloading)
        } catch {
            // 标记「下载中」都失败：交给 storeFailed 把本地状态退回 queued，
            // 不把这次失败误记成章节下载失败。
            await send(.storeFailed(error.localizedDescription))
            return
        }
        do {
            let text = try await downloader.download(task.chapterPath)
            if waitNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: waitNanoseconds)
            }
            await send(.downloaderSucceeded(task.id, text))
        } catch {
            await send(.downloaderFailed(task.id, classifyDownloadFailure(error)))
        }
    }
}

private func delayNanoseconds(for speed: DownloadSpeed) -> UInt64 {
    switch speed {
    case .conservative:
        // 需求给的区间是 0.5~1 秒，固定取中点，避免每次随机波动。
        750_000_000
    case .fast:
        0
    }
}

private func bookTitle(in state: DownloadFeature.State, bookPath: String) -> String {
    state.tasks.first { $0.bookPath == bookPath }?.bookTitle ?? "该书籍"
}

/// 把一个状态变更持久化，并带走完整队列快照。
private func persist(
    mutation: DownloadTaskMutation,
    ids: [String],
    with store: DownloadQueueStore
) -> Effect<DownloadFeature.Action> {
    .run { send in
        do {
            try await send(.persisted(store.mutate(ids, mutation)))
        } catch {
            await send(.storeFailed(error.localizedDescription))
        }
    }
}

/// 章节正文下载器（依赖）。
///
/// 下载功能不直接调用引擎单例，测试只替换一个闭包即可驱动完整状态机。
struct ChapterDownloader: Sendable {
    var download: @Sendable (String) async throws -> String
}

extension DependencyValues {
    var chapterDownloader: ChapterDownloader {
        get { self[ChapterDownloaderKey.self] }
        set { self[ChapterDownloaderKey.self] = newValue }
    }

    private enum ChapterDownloaderKey: DependencyKey {
        static let liveValue = ChapterDownloader { chapterPath in
            try await NovelEngine.shared.content(chapterPath: chapterPath)
        }

        /// 测试默认值：返回空串，避免忘记注入桩的测试意外联网。
        static let testValue = ChapterDownloader { _ in "" }
    }
}
