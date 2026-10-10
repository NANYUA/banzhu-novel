/// 下载队列状态。
///
/// ## 为什么单独一个文件
/// 原先是 `DownloadFeature.swift` 里紧跟在 reducer body 之后的一段 `extension`，
/// 本轮的「书卡 + 选择模式」要给 `State` 加两个存储属性、给 `Action` 加若干分支，
/// 而那个文件已经 585 行（SwiftLint `file_length` warning 600 ⇒ CI `--strict` 下即失败）。
/// 把**整段状态**原样搬到本文件，是这次唯一能腾出余量又不动行为的拆法
/// （拆法沿用 `BookshelfView+GroupBar` 的先例：`X+子主题.swift`）。
///
/// ## 为什么状态与 reducer body 分开声明
/// SwiftLint 的 `type_body_length` 会把嵌套类型算进外层类型，
/// `State` 挤在 `DownloadFeature` body 里必然超限（`type_body_length` **不计** extension）。
public extension DownloadFeature {
    struct State: Equatable {
        public init(
            tasks: [DownloadTaskSnapshot] = [],
            isPaused: Bool = false,
            allowsCellular: Bool = false,
            speed: DownloadSpeed = .conservative,
            networkKind: DownloadNetworkKind = .unknown,
            isDownloading: Bool = false,
            notice: String? = nil,
            isSelecting: Bool = false,
            selectedBookPaths: Set<String> = []
        ) {
            self.tasks = tasks
            self.isPaused = isPaused
            self.allowsCellular = allowsCellular
            self.speed = speed
            self.networkKind = networkKind
            self.isDownloading = isDownloading
            self.notice = notice
            self.isSelecting = isSelecting
            self.selectedBookPaths = selectedBookPaths
        }

        /// 持久化任务的只读投影，按入队顺序排列。
        public var tasks: [DownloadTaskSnapshot] = []

        /// 全局暂停开关。
        public var isPaused = false

        /// 是否允许蜂窝网络启动下载；默认只允许 WiFi。
        public var allowsCellular = false

        /// 速率档位；默认保守档。
        public var speed: DownloadSpeed = .conservative

        /// 系统当前网络类型。
        public var networkKind: DownloadNetworkKind = .unknown

        /// 是否已经监听系统网络变化，防止多个视图重复启动监听。
        var isObservingNetwork = false

        /// 当前是否有下载 Effect 在跑。
        public var isDownloading = false

        /// 面向用户的横幅提示。
        public var notice: String?

        /// 是否处于选择模式（长按书卡进入，与书架 `BookshelfFeature.State.isEditing` 同一交互）。
        public var isSelecting = false

        /// 选择模式下勾选的书 `bookPath`。
        ///
        /// 🔴 勾选的单位是**书**（`bookPath`），不是章节 —— 队列里一本书可能有很多条
        /// 章节任务，而书卡只有一张。判据与 `bookPaths` 同源，见 `DownloadFeature+Selection.swift`。
        public var selectedBookPaths: Set<String> = []

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

        /// 这本书已完成（`.done`）章节的 `chapterPath` 集合（纯内存派生：不读库、不新增订阅）。
        ///
        /// 详情页据此把**刚下完**的章节就地标成已下载，不改「已下载」的唯一真相
        /// （仍是 `ChapterRecord.source == .downloaded`）。
        ///
        /// 本书的过滤只比 `DownloadTaskSnapshot.bookPath` 字段：**不拼也不拆**
        /// `bookPath#chapterPath` 复合键，所以调用方不必知道键的形态，
        /// 键格式将来变化也不会在这一层之外静默失配。
        ///
        /// 完成的任务**不会**被移出队列（`DownloadQueueStoreLive.complete(taskID:text:)`
        /// 只把任务 `markDone()`，只有 `cancelBook` 才会 `remove`），所以 `.done` 是稳定信号。
        public func completedChapterPaths(forBook bookPath: String) -> Set<String> {
            Set(tasks.filter { $0.state.isFinished && $0.bookPath == bookPath }.map(\.chapterPath))
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
