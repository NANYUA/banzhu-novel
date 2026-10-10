import Dependencies
import Foundation
import NovelEngine
import SwiftData

/// 阅读时自动缓存当前章与后续章节。
///
/// 自动缓存统一标记为 `.cached`，计入 LRU 上限；
/// 用户下载的 `.downloaded` 不参与缓存淘汰，其正文默认不覆盖 ——
/// **仅当它已过期**（`savedAt` 早于正文世代）时才允许用新拉到的完整正文自愈覆盖。
struct ChapterCacheStore: Sendable {
    var cacheCurrentAndFollowing: @Sendable (String, String, Int) async -> Void
}

extension DependencyValues {
    var chapterCacheStore: ChapterCacheStore {
        get { self[ChapterCacheStoreKey.self] }
        set { self[ChapterCacheStoreKey.self] = newValue }
    }

    private enum ChapterCacheStoreKey: DependencyKey {
        static let liveValue = ChapterCacheStore { chapterPath, currentText, followingCount in
            await ChapterCacheStoreLive.cacheCurrentAndFollowing(
                chapterPath: chapterPath,
                currentText: currentText,
                followingCount: followingCount
            )
        }

        /// 测试默认值：不做网络与磁盘操作。
        static let testValue = ChapterCacheStore { _, _, _ in }
    }
}

/// 自动缓存规划：后续 N 章中尚无本地正文的章节。
enum ChapterCachePlanner {
    static func planFollowing(
        currentChapterPath: String,
        chapters: [ChapterRecord],
        followingCount: Int
    ) -> [ChapterRecord] {
        guard let current = chapters.first(where: { $0.path == currentChapterPath }) else {
            return []
        }
        let bookChapters = chapters
            .filter { $0.bookPath == current.bookPath }
            .sorted { $0.number < $1.number }
        guard let currentIndex = bookChapters.firstIndex(where: { $0.path == currentChapterPath }) else {
            return []
        }

        return bookChapters[(currentIndex + 1)...]
            .prefix(max(0, followingCount))
            .filter { $0.source != .downloaded && !$0.hasLocalText }
    }
}

/// 自动缓存真实实现。
@MainActor
enum ChapterCacheStoreLive {
    /// 保守档请求间隔，与下载队列一致，避免连续请求触发站点防护。
    static let defaultRequestIntervalNanoseconds: UInt64 = 750_000_000

    static func cacheCurrentAndFollowing(
        chapterPath: String,
        currentText: String,
        followingCount: Int
    ) async {
        guard let context = try? ModelContext(NovelStore.makeContainer()) else { return }
        await cache(
            chapterPath: chapterPath,
            currentText: currentText,
            followingCount: followingCount,
            in: context
        ) { path in
            try await NovelEngine.shared.content(chapterPath: path)
        }
    }

    /// 可注入容器与正文加载器的实现，供测试直接验证落盘规则。
    static func cache(
        chapterPath: String,
        currentText: String,
        followingCount: Int,
        in context: ModelContext,
        load: (String) async throws -> String
    ) async {
        let chapters = (try? context.fetch(FetchDescriptor<ChapterRecord>())) ?? []
        if let current = chapters.first(where: { $0.path == chapterPath }) {
            try? saveCachedText(currentText, for: current, in: context)
        }

        let candidates = ChapterCachePlanner.planFollowing(
            currentChapterPath: chapterPath,
            chapters: chapters,
            followingCount: followingCount
        )

        for (index, chapter) in candidates.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: defaultRequestIntervalNanoseconds)
            }
            do {
                let text = try await load(chapter.path)
                try saveCachedText(text, for: chapter, in: context)
            } catch {
                // 自动缓存失败不阻断阅读，也不继续连续请求。
                break
            }
        }

        try? NovelStore.evictCachedChapters(in: context)
    }

    /// 落盘一章正文。
    ///
    /// ## 覆盖口径（原先是一律不覆盖 `.downloaded`，现按「过期与否」收窄）
    /// `.downloaded` 的正文默认不覆盖，**仅在它已过期**时允许用新拉到的完整正文
    /// 覆盖其正文文件；`source` 保持 `.downloaded` 不变 ⇒ 契约 ①「已下载的唯一真相是
    /// `source == .downloaded`」与契约 ②「下载的章节永不被淘汰」都不受影响。
    static func saveCachedText(
        _ text: String,
        for chapter: ChapterRecord,
        in context: ModelContext,
        epoch: Date = ContentEpoch.current()
    ) throws {
        if chapter.source == .downloaded {
            // 新鲜的下载正文一律不碰；只有过期的才允许自愈覆盖。
            guard ContentEpoch.isStale(savedAt: chapter.savedAt, epoch: epoch) else { return }
        }

        let url = NovelStore.chapterFile(bookPath: chapter.bookPath, number: chapter.number)
        // ⚠️ 内容相同就什么都不做（不写文件、不刷新 `savedAt`）。
        // 这一步不能省：离线兜底会把**过期的旧正文**原样再传进来，
        // 直接写就会把 `savedAt` 刷成现在 ⇒ 坏正文永久伪装成「新鲜」，再也无法自愈。
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text {
            return
        }

        let fileName = try NovelStore.saveChapterText(
            text,
            bookPath: chapter.bookPath,
            number: chapter.number
        )
        if chapter.source != .downloaded {
            chapter.source = .cached
        }
        chapter.localFileName = fileName
        chapter.savedAt = Date()
        try context.save()
    }
}
