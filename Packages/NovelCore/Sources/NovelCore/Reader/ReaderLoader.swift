import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 章节正文加载器（依赖）。
///
/// ## 为什么收进依赖
/// 与 `ShelfLoader` 同理：reducer 若直接碰网络，测试就得 mock 网络。
/// 收进依赖后，测试用 `withDependencies` 换成内存桩，断言的仍是完整的状态迁移。
struct ReaderLoader: Sendable {
    /// 加载一章正文。参数是章节路径（如 `/49/49034/123.html`）。
    var load: @Sendable (String) async throws -> String
}

extension DependencyValues {
    /// 章节加载器。测试里用 `withDependencies { $0.readerLoader.load = { … } }` 替换。
    var readerLoader: ReaderLoader {
        get { self[ReaderLoaderKey.self] }
        set { self[ReaderLoaderKey.self] = newValue }
    }

    private enum ReaderLoaderKey: DependencyKey {
        static let liveValue = ReaderLoader { chapterPath in
            try await ReaderLoaderLive.loadWithHeal(chapterPath: chapterPath) { path in
                try await NovelEngine.shared.content(chapterPath: path)
            }
        }

        /// 测试默认值：返回空串，避免忘记注入桩的测试意外联网。
        static let testValue = ReaderLoader { _ in "" }
    }
}

/// 阅读正文的本地缓存读取与**自愈**。
///
/// 本地正文**新鲜**就直接用（已缓存秒开、离线可读，不发网络请求）；
/// 本地正文**过期**（可能是旧构建写下的不完整正文）或没有本地正文时才联网；
/// 联网失败则退回过期的本地正文 —— 少一段好过整章空白。
@MainActor
enum ReaderLoaderLive {
    /// 生产接线：本地新鲜即返回本地，过期或缺失才联网，联网失败退回旧正文。
    static func loadWithHeal(
        chapterPath: String,
        fetch: (String) async throws -> String
    ) async throws -> String {
        guard let context = try? ModelContext(NovelStore.makeContainer()) else {
            return try await fetch(chapterPath)
        }
        return try await loadWithHeal(chapterPath: chapterPath, in: context, fetch: fetch)
    }

    /// 可注入容器 / 世代 / 正文加载器的实现，供测试直接验证自愈规则。
    static func loadWithHeal(
        chapterPath: String,
        in context: ModelContext,
        epoch: Date = ContentEpoch.current(),
        fetch: (String) async throws -> String
    ) async throws -> String {
        let local = try? load(chapterPath: chapterPath, in: context, epoch: epoch)
        if let local, !local.isStale {
            return local.text
        }
        do {
            return try await fetch(chapterPath)
        } catch {
            // 离线兜底：返回过期的本地正文。它会在下次联网成功时被完整正文替换。
            if let local {
                return local.text
            }
            throw error
        }
    }

    /// 读取本地正文，并回报它是否「过期」（`savedAt` 早于本安装的正文世代）。
    static func load(
        chapterPath: String,
        in context: ModelContext,
        epoch: Date = ContentEpoch.current()
    ) throws -> (text: String, isStale: Bool)? {
        let descriptor = FetchDescriptor<ChapterRecord>(
            predicate: #Predicate { $0.path == chapterPath }
        )
        guard let chapter = try context.fetch(descriptor).first, chapter.hasLocalText else {
            return nil
        }
        let text = try NovelStore.loadChapterText(
            bookPath: chapter.bookPath,
            number: chapter.number
        )
        return (text, ContentEpoch.isStale(savedAt: chapter.savedAt, epoch: epoch))
    }
}

/// 分页服务（依赖）—— 把「用哪个度量器分页」的决策藏起来。
///
/// ## 为什么需要它
/// `Paginator` 是纯 Swift 的，但真实度量 `TextKitMeasuring` 在 NovelPagination
/// （import UIKit）。NovelCore 不能依赖 NovelPagination（会破坏依赖方向）。
/// 所以「分页」这个能力通过依赖注入：
/// - 测试：注入 `Paginator(measurer: FakeMeasuring())`
/// - 真机：App 层注入 `Paginator(measurer: TextKitMeasuring())`
public struct PaginationService: Sendable {
    /// 把 `text` 按 `configuration` 切成页
    public var paginate: @Sendable (String, PaginationConfiguration) -> [PageRange]

    public init(paginate: @escaping @Sendable (String, PaginationConfiguration) -> [PageRange]) {
        self.paginate = paginate
    }
}

extension DependencyValues {
    /// 分页服务。测试注入 FakeMeasuring，真机注入 TextKitMeasuring。
    public var paginationService: PaginationService {
        get { self[PaginationServiceKey.self] }
        set { self[PaginationServiceKey.self] = newValue }
    }

    private enum PaginationServiceKey: DependencyKey {
        /// 默认：用纯逻辑 Paginator + FakeMeasuring（占位）。
        /// 真机由 App 层在创建 store 时用 TextKitMeasuring 覆盖。
        static let liveValue = PaginationService { text, config in
            Paginator(measurer: FakeMeasuringForLive()).paginate(text: text, configuration: config)
        }

        static let testValue = PaginationService { text, config in
            Paginator(measurer: FakeMeasuringForLive()).paginate(text: text, configuration: config)
        }
    }
}

/// 生产环境的临时度量（占位，等 App 层注入 TextKitMeasuring）。
/// 用宽预算 10 模拟「每页约 5 个中文字」，保证真机能跑但分页是近似的。
/// ⚠️ 正式版必须用 TextKitMeasuring，这只是让 ReaderFeature 能独立测试。
private struct FakeMeasuringForLive: TextMeasuring {
    func measurePageLength(text: String, from: Int, configuration _: PaginationConfiguration) -> Int {
        let chars = Array(text)
        var width = 0
        var count = 0
        for index in from ..< chars.count {
            // 简化：汉字按 2、ASCII 按 1
            let charWidth = (chars[index].unicodeScalars.first?.value ?? 0) > 0x2E80 ? 2 : 1
            if width + charWidth > 10 {
                break
            }
            width += charWidth
            count += 1
        }
        return count
    }
}
