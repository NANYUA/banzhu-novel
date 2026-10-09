import ComposableArchitecture
import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 书籍详情快照。字段全部来自搜索/详情页解析，缺失时留空，由 UI 显示“暂无”。
public struct BookDetail: Equatable, Identifiable, Sendable {
    public init(book: Book) {
        bookPath = book.path
        title = book.title
        author = book.author
        coverUrl = book.coverUrl
        intro = book.intro
        status = book.status
        category = book.category
        tags = book.tags
        wordCount = book.wordCount
        lastChapter = book.lastChapter
        lastUpdated = book.lastUpdated
    }

    public init(
        bookPath: String,
        title: String,
        author: String = "",
        coverUrl: String = "",
        intro: String = "",
        status: String = "",
        category: String = "",
        tags: [String] = [],
        wordCount: String = "",
        lastChapter: String = "",
        lastUpdated: String = "",
        lastReadChapterPath: String? = nil,
        lastReadChapterName: String? = nil
    ) {
        self.bookPath = bookPath
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.status = status
        self.category = category
        self.tags = tags
        self.wordCount = wordCount
        self.lastChapter = lastChapter
        self.lastUpdated = lastUpdated
        self.lastReadChapterPath = lastReadChapterPath
        self.lastReadChapterName = lastReadChapterName
    }

    public var id: String {
        bookPath
    }

    public var bookPath: String
    public var title: String
    public var author: String
    public var coverUrl: String
    public var intro: String
    public var status: String
    public var category: String
    public var tags: [String]
    public var wordCount: String
    public var lastChapter: String
    public var lastUpdated: String

    /// 上次读到的章节路径（本地 `BookRecord.lastReadChapterPath`）。
    ///
    /// 搜索 / 详情解析拿不到这个信息，只有本地已有这本书的记录时才非 nil ——
    /// 详情页的「继续阅读」据此定位（见 `BookDetailFeature.State.continueChapter`）。
    public var lastReadChapterPath: String?

    /// 上次读到的章节名（仅用于展示；定位一律用路径）。
    public var lastReadChapterName: String?
}

public extension BookDetail {
    /// 详情 → 引擎书模型。
    ///
    /// 「加入书架」复用 `ShelfAdder.add(_:)` 这条**既有**落库路径（与搜索结果页同一条），
    /// 所以详情页需要把快照还原成 `Book`，而不是新造一条「按 bookPath 加书」的依赖。
    /// 字段与 `Book` 一一对应，其中详情页独有的 `intro` 等也只做搬运，不做加工。
    var book: Book {
        var model = Book(path: bookPath, title: title)
        model.author = author
        model.intro = intro
        model.lastChapter = lastChapter
        model.wordCount = wordCount
        model.coverUrl = coverUrl
        model.status = status
        model.category = category
        model.tags = tags
        model.lastUpdated = lastUpdated
        return model
    }
}

/// 详情页 reducer。
///
/// ## 现在它还管什么（U1-4 / U1-6 / U1-7）
/// - **站点 host（U1-4）**：从用户配置里读当前 host，界面据此现场拼出「转到原网站」的 URL。
///   本层不缓存、不硬编码任何域名 —— 没配置 host 时 `sourceURL` 为 nil，入口整体隐藏。
/// - **目录（U1-6）**：自己经 `chapterListLoader` 读本地目录快照，直接给详情页内嵌渲染；
///   默认只暴露前 `chapterPreviewLimit` 条，其余靠 `toggleAllChapters` 就地展开。
/// - **下载口径（U1-7）**：已下载章节数 / 可下载章节数由 `chapters` 派生，
///   判定一律走 `ChapterItem.isDownloaded`（= `ChapterRecord.source == .downloaded`），
///   不绕过 `source` 标记自己猜「下没下过」。
public struct BookDetailFeature: Reducer {
    public init() {}

    public enum Action: Equatable {
        case onAppear
        /// 站点 host 读取完成（`SiteSettings.currentHostValue`，未配置时为空串）。
        case hostLoaded(String)
        /// 详情加载完成。`nil` 表示本地没有这本书的记录 —— 也就是**不在书架**。
        case loaded(BookDetail?)
        case loadFailed(String)

        /// 目录加载完成。
        case chaptersLoaded([ChapterItem])
        /// 目录加载失败（与详情失败分开记，一个失败不该把另一个也拖下水）。
        case chaptersFailed(String)
        /// 目录加载失败后点「重试」：只重发目录请求，不重新读详情。
        case reloadChapters
        /// 「查看全部目录 / 收起目录」。
        case toggleAllChapters

        /// 点「加入书架」。
        case addRequested
        case addSucceeded(ShelfRow)
        /// 加入失败。`alreadyExists` 为 `true` 表示失败原因是「这本书已在书架里」——
        /// 界面要据此切到「移出书架」，而不是留在「加入书架」让用户反复点到失败。
        case addFailed(message: String, alreadyExists: Bool)

        /// 点「移出书架」。
        case removeRequested
        case removeSucceeded
        case removeFailed(String)
    }

    @Dependency(\.bookDetailLoader) var loader
    @Dependency(\.chapterListLoader) var chapterListLoader
    @Dependency(\.siteStore) var siteStore
    @Dependency(\.shelfAdder) var shelfAdder
    @Dependency(\.shelfGroupStore) var shelfGroupStore

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                state.isLoadingChapters = true
                state.chapterErrorMessage = nil
                let bookPath = state.fallback.bookPath
                let loader = loader
                let chapterListLoader = chapterListLoader
                let siteStore = siteStore
                return .run { send in
                    // host 现场读（不缓存、不硬编码）；读不到就是空串，界面自己决定隐藏入口。
                    let settings = await siteStore.load()
                    await send(.hostLoaded(settings.currentHostValue ?? ""))

                    // 三段**串行**发送，而不是并发 effect：三步都是本地读，串行不拖慢首屏，
                    // 却能让动作顺序确定 —— 并发 effect 的到达顺序不可断言，测试会变成掷骰子。
                    do {
                        let detail = try await loader.load(bookPath)
                        await send(.loaded(detail))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                    do {
                        let chapters = try await chapterListLoader.load(bookPath)
                        await send(.chaptersLoaded(chapters))
                    } catch {
                        await send(.chaptersFailed(error.localizedDescription))
                    }
                }

            case let .hostLoaded(host):
                state.host = host
                return .none

            case let .loaded(loaded):
                // 🔴 `nil` 就是「不在书架」：`BookDetailLoaderLive` 只在命中 `BookRecord`
                // （加入书架时才写入）时返回非 nil，读不到记录必然意味着没加过。
                state.isOnShelf = loaded != nil
                state.detail = loaded ?? state.fallback
                state.isLoading = false
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case let .chaptersLoaded(chapters):
                state.chapters = chapters
                state.isLoadingChapters = false
                return .none

            case let .chaptersFailed(message):
                state.isLoadingChapters = false
                state.chapterErrorMessage = message
                return .none

            case .reloadChapters:
                guard !state.isLoadingChapters else { return .none }
                state.isLoadingChapters = true
                state.chapterErrorMessage = nil
                let bookPath = state.detail.bookPath
                let chapterListLoader = chapterListLoader
                return .run { send in
                    do {
                        let chapters = try await chapterListLoader.load(bookPath)
                        await send(.chaptersLoaded(chapters))
                    } catch {
                        await send(.chaptersFailed(error.localizedDescription))
                    }
                }

            case .toggleAllChapters:
                state.isShowingAllChapters.toggle()
                return .none

            case .addRequested:
                // 已在书架 / 正在处理时不重复发请求（此时按钮本应是「移出书架」）。
                guard !state.isShelfBusy, !state.isOnShelf else { return .none }
                state.isShelfBusy = true
                state.shelfNotice = nil
                let book = state.detail.book
                let adder = shelfAdder
                return .run { send in
                    do {
                        let row = try await adder.add(book)
                        await send(.addSucceeded(row))
                    } catch let error as ShelfAdderError {
                        // 显式 switch 而非 `if case`：`ShelfAdderError` 将来加 case 时这里会编译报错。
                        switch error {
                        case .alreadyExists:
                            await send(.addFailed(
                                message: error.localizedDescription,
                                alreadyExists: true
                            ))
                        }
                    } catch {
                        await send(.addFailed(
                            message: error.localizedDescription,
                            alreadyExists: false
                        ))
                    }
                }

            case let .addSucceeded(row):
                state.isShelfBusy = false
                state.isOnShelf = true
                state.lastAddedRow = row
                return .none

            case let .addFailed(message, alreadyExists):
                state.isShelfBusy = false
                state.shelfNotice = message
                // 已经在书架里 == 状态其实是「已加入」，顺手把按钮切对。
                if alreadyExists {
                    state.isOnShelf = true
                }
                return .none

            case .removeRequested:
                guard !state.isShelfBusy, state.isOnShelf else { return .none }
                state.isShelfBusy = true
                state.shelfNotice = nil
                let bookPath = state.detail.bookPath
                let store = shelfGroupStore
                return .run { send in
                    do {
                        // 复用书架批量删书那条既有路径（清元数据 + 清正文文件 + 清下载任务），
                        // 这里一次只传一本 —— 不新造「单本移除」，避免两套清理逻辑分叉。
                        try await store.removeBooks([bookPath])
                        await send(.removeSucceeded)
                    } catch {
                        await send(.removeFailed(error.localizedDescription))
                    }
                }

            case .removeSucceeded:
                state.isShelfBusy = false
                state.isOnShelf = false
                state.lastRemovedPath = state.detail.bookPath
                return .none

            case let .removeFailed(message):
                state.isShelfBusy = false
                state.shelfNotice = message
                return .none
            }
        }
    }
}

// MARK: - 状态

/// 详情页状态。
///
/// ⚠️ 与 reducer body 分开声明（同 `DownloadFeature`）：SwiftLint 的 `type_body_length`
/// 会把嵌套类型算进外层类型，State 挤在 `BookDetailFeature` body 里必然超限。
public extension BookDetailFeature {
    struct State: Equatable {
        public init(fallback: BookDetail) {
            self.fallback = fallback
            detail = fallback
        }

        public var fallback: BookDetail
        public var detail: BookDetail
        public var isLoading = false
        public var errorMessage: String?

        /// 这本书当前是否已在书架。界面据此在「加入书架 / 移出书架」之间切换。
        ///
        /// 🔴 只在 `onAppear` 读一次本地记录（命中 `BookRecord` == 已在书架），
        /// 不在渲染路径上查库；加入 / 移出成功后由对应 action 直接改这个值。
        public var isOnShelf = false

        /// 加入 / 移出进行中。同一页一次只可能有一个书架操作，用布尔即可。
        public var isShelfBusy = false

        /// 加入 / 移出失败提示（就地显示在按钮下方，不阻断页面）。
        public var shelfNotice: String?

        /// 最近一次成功加入的书架行，供上层（搜索页）即时同步列表。
        /// 与 `SearchFeature.lastAddedRow` 同一套路：本层不知道谁在用，只把结果抛出去。
        public var lastAddedRow: ShelfRow?

        /// 最近一次移出书架的书路径，供上层（书架页 / 搜索页）把这本书从列表里摘掉。
        public var lastRemovedPath: String?

        /// 用户当前配置的站点 host（`SiteSettings.currentHostValue`）。
        ///
        /// 空串 = 还没配置站点 → 「转到原网站」入口整体隐藏（不给点了没反应的按钮）。
        public var host = ""

        /// 目录快照（本地，按章号升序）。U1-6 起直接内嵌在详情页里，不再单独 push 目录页。
        public var chapters: [ChapterItem] = []

        /// 目录首次加载中。
        public var isLoadingChapters = false

        /// 目录加载失败原因。与详情本身的 `errorMessage` **分开**：一个失败不该把另一个拖下水。
        public var chapterErrorMessage: String?

        /// 目录是否已展开为全部章节。默认只渲染前 `chapterPreviewLimit` 条。
        public var isShowingAllChapters = false
    }
}

/// 详情页状态的派生值（避免这些口径散落到 View 里各算一遍）。
public extension BookDetailFeature.State {
    /// 目录默认内嵌渲染的章节条数上限。
    /// 章数很多的书不做一次性渲染（`LazyVStack` 也只是懒布局，元素仍要参与 diff）。
    static let chapterPreviewLimit = 12

    /// 真正交给 `LazyVStack` 渲染的章节：未展开时只给前 N 条。
    var visibleChapters: [ChapterItem] {
        isShowingAllChapters ? chapters : Array(chapters.prefix(Self.chapterPreviewLimit))
    }

    /// 目录里还有没有没渲染出来的章节（决定「查看全部目录」按钮出不出现）。
    var hasHiddenChapters: Bool {
        chapters.count > visibleChapters.count
    }

    /// 已下载的章节数。判定走 `ChapterItem.isDownloaded`（来自 `ChapterRecord.source`），
    /// 不绕过 source 标记自己猜「下没下过」。
    var downloadedChapterCount: Int {
        chapters.filter(\.isDownloaded).count
    }

    /// 尚未下载、可被勾选下载的章节数。
    var downloadableChapterCount: Int {
        chapters.filter { !$0.isDownloaded }.count
    }

    /// 「继续阅读」的目标章节。
    ///
    /// 只有本地上次阅读记录命中的那一章**还在目录里**时才返回它 ——
    /// 记录指向的章节已消失（站点改版）时宁可退回 nil，让界面走「开始阅读」。
    var continueChapter: ChapterItem? {
        guard let path = detail.lastReadChapterPath, !path.isEmpty else { return nil }
        return chapters.first { $0.path == path }
    }

    /// 「转到原网站」的目标 URL：由**用户当前配置的 host** + 本书 `bookPath` 现场拼出。
    ///
    /// 🔴 脱敏硬约束：这里不允许出现任何写死的域名 / IP / 路径特征。
    /// - host 来自 `SiteSettings.currentHostValue`（用户配置，可为 `example.com` 这种无协议写法，
    ///   先用 `SiteRoutingConfiguration.normalizedHost` 补全协议再拼）；
    /// - 返回 `nil` 表示**没有可用 host**，界面据此隐藏入口。
    var sourceURL: URL? {
        let normalizedHost = SiteRoutingConfiguration.normalizedHost(host)
        guard !normalizedHost.isEmpty else { return nil }
        let bookPath = detail.bookPath
        let path = bookPath.hasPrefix("/") ? bookPath : "/" + bookPath
        return SiteConfig(host: normalizedHost).url(path)
    }
}

// MARK: - 依赖

struct BookDetailLoader: Sendable {
    var load: @Sendable (String) async throws -> BookDetail?
}

extension DependencyValues {
    var bookDetailLoader: BookDetailLoader {
        get { self[BookDetailLoaderKey.self] }
        set { self[BookDetailLoaderKey.self] = newValue }
    }

    private enum BookDetailLoaderKey: DependencyKey {
        static let liveValue = BookDetailLoader { bookPath in
            try await BookDetailLoaderLive.load(bookPath: bookPath)
        }

        static let testValue = BookDetailLoader { _ in nil }
    }
}

@MainActor
private enum BookDetailLoaderLive {
    static func load(bookPath: String) throws -> BookDetail? {
        let context = try ModelContext(NovelStore.makeContainer())
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.bookPath == bookPath }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return BookDetail(
            bookPath: record.bookPath,
            title: record.title,
            author: record.author,
            coverUrl: record.coverUrl,
            intro: record.intro,
            status: record.status,
            category: record.category,
            tags: record.tags
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            wordCount: record.wordCount,
            lastChapter: record.latestChapterName ?? "",
            lastUpdated: record.lastUpdated,
            // 阅读位置只存在本地记录里 —— 「继续阅读」全靠这两个字段。
            lastReadChapterPath: record.lastReadChapterPath,
            lastReadChapterName: record.lastReadChapterName
        )
    }
}
