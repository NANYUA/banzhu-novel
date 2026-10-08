import Dependencies
import Foundation
import SwiftData

/// 书架分组的只读投影。
///
/// 「全部」不占记录（见 `BookGroup`），这里只列用户创建的分组。
public struct ShelfGroupSnapshot: Equatable, Identifiable, Sendable {
    public init(id: UUID, name: String, sortIndex: Int) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }

    public let id: UUID
    public let name: String
    public let sortIndex: Int
}

/// 书架分组读写依赖（D13：一级手动分组）。
///
/// reducer 不直接碰 SwiftData；这里把「分组 CRUD、批量归类、删书清理」
/// 收在同一层，测试可以完全替换为内存桩。
struct ShelfGroupStore: Sendable {
    var loadGroups: @Sendable () async throws -> [ShelfGroupSnapshot]
    var createGroup: @Sendable (String) async throws -> ShelfGroupSnapshot
    var renameGroup: @Sendable (UUID, String) async throws -> Void
    var deleteGroup: @Sendable (UUID) async throws -> Void
    var assignBooks: @Sendable ([String], UUID?) async throws -> Void
    var removeBooks: @Sendable ([String]) async throws -> Void
}

extension DependencyValues {
    var shelfGroupStore: ShelfGroupStore {
        get { self[ShelfGroupStoreKey.self] }
        set { self[ShelfGroupStoreKey.self] = newValue }
    }

    private enum ShelfGroupStoreKey: DependencyKey {
        static let liveValue = ShelfGroupStore(
            loadGroups: { try await ShelfGroupStoreLive.loadGroups() },
            createGroup: { try await ShelfGroupStoreLive.createGroup(name: $0) },
            renameGroup: { id, name in
                try await ShelfGroupStoreLive.renameGroup(id: id, name: name)
            },
            deleteGroup: { id in
                try await ShelfGroupStoreLive.deleteGroup(id: id)
            },
            assignBooks: { paths, groupID in
                try await ShelfGroupStoreLive.assignBooks(bookPaths: paths, groupID: groupID)
            },
            removeBooks: { paths in
                try await ShelfGroupStoreLive.removeBooks(bookPaths: paths)
            }
        )

        /// 测试默认值：空分组、无操作。
        static let testValue = ShelfGroupStore(
            loadGroups: { [] },
            createGroup: { name in
                ShelfGroupSnapshot(id: UUID(), name: name, sortIndex: 0)
            },
            renameGroup: { _, _ in },
            deleteGroup: { _ in },
            assignBooks: { _, _ in },
            removeBooks: { _ in }
        )
    }
}

/// 书架分组与批量删书的真实实现。
@MainActor
enum ShelfGroupStoreLive {
    static func loadGroups() throws -> [ShelfGroupSnapshot] {
        let context = try ModelContext(NovelStore.makeContainer())
        let groups = (try? context.fetch(FetchDescriptor<BookGroup>())) ?? []
        return BookGroup.userGroups(from: groups).map {
            ShelfGroupSnapshot(id: $0.id, name: $0.name, sortIndex: $0.sortIndex)
        }
    }

    static func createGroup(name: String) throws -> ShelfGroupSnapshot {
        let context = try ModelContext(NovelStore.makeContainer())
        let groups = (try? context.fetch(FetchDescriptor<BookGroup>())) ?? []
        let group = BookGroup(name: name, sortIndex: groups.count)
        context.insert(group)
        try context.save()
        return ShelfGroupSnapshot(id: group.id, name: group.name, sortIndex: group.sortIndex)
    }

    static func renameGroup(id: UUID, name: String) throws {
        let context = try ModelContext(NovelStore.makeContainer())
        guard let group = try fetchGroup(id: id, in: context) else { return }
        group.name = name
        try context.save()
    }

    static func deleteGroup(id: UUID) throws {
        let context = try ModelContext(NovelStore.makeContainer())
        guard let group = try fetchGroup(id: id, in: context) else { return }
        // 分组删除后，原本属于它的书回到「未分组」，不能连书一起删。
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        for book in books where book.groupId == id {
            book.groupId = nil
        }
        context.delete(group)
        try context.save()
    }

    static func assignBooks(bookPaths: [String], groupID: UUID?) throws {
        guard !bookPaths.isEmpty else { return }
        let context = try ModelContext(NovelStore.makeContainer())
        let selected = Set(bookPaths)
        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        for book in books where selected.contains(book.bookPath) {
            book.groupId = groupID
        }
        try context.save()
    }

    /// 删除书架里的书：清元数据、清正文文件、清该书下载任务。
    static func removeBooks(bookPaths: [String]) throws {
        guard !bookPaths.isEmpty else { return }
        let context = try ModelContext(NovelStore.makeContainer())
        let selected = Set(bookPaths)

        let books = (try? context.fetch(FetchDescriptor<BookRecord>())) ?? []
        let chapters = (try? context.fetch(FetchDescriptor<ChapterRecord>())) ?? []
        let tasks = (try? context.fetch(FetchDescriptor<DownloadTask>())) ?? []

        for book in books where selected.contains(book.bookPath) {
            context.delete(book)
        }
        for chapter in chapters where selected.contains(chapter.bookPath) {
            NovelStore.deleteChapterText(bookPath: chapter.bookPath, number: chapter.number)
            context.delete(chapter)
        }
        for task in tasks where selected.contains(task.bookPath) {
            context.delete(task)
        }
        try context.save()
    }

    private static func fetchGroup(id: UUID, in context: ModelContext) throws -> BookGroup? {
        var descriptor = FetchDescriptor<BookGroup>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
