import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 书籍详情页。展示网站详情页字段，并作为进入目录/阅读的唯一入口。
struct BookDetailView: View {
    let store: StoreOf<BookDetailFeature>
    let downloadStore: StoreOf<DownloadFeature>

    /// 加入书架成功后回调，供上层同步自己的列表（书架页 / 搜索页都可能是上层）。
    let onAddedToShelf: (ShelfRow) -> Void

    /// 移出书架成功后回调，供上层把这本书从列表里摘掉。
    let onRemovedFromShelf: (String) -> Void

    @State private var isIntroExpanded = false
    @State private var isShowingChapterList = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        book: Book,
        downloadStore: StoreOf<DownloadFeature>,
        onAddedToShelf: @escaping (ShelfRow) -> Void = { _ in },
        onRemovedFromShelf: @escaping (String) -> Void = { _ in }
    ) {
        self.downloadStore = downloadStore
        self.onAddedToShelf = onAddedToShelf
        self.onRemovedFromShelf = onRemovedFromShelf
        store = Store(initialState: BookDetailFeature.State(fallback: BookDetail(book: book))) {
            BookDetailFeature()
        }
    }

    init(
        bookPath: String,
        title: String,
        downloadStore: StoreOf<DownloadFeature>,
        onAddedToShelf: @escaping (ShelfRow) -> Void = { _ in },
        onRemovedFromShelf: @escaping (String) -> Void = { _ in }
    ) {
        self.downloadStore = downloadStore
        self.onAddedToShelf = onAddedToShelf
        self.onRemovedFromShelf = onRemovedFromShelf
        store = Store(
            initialState: BookDetailFeature.State(
                fallback: BookDetail(bookPath: bookPath, title: title)
            )
        ) {
            BookDetailFeature()
        }
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(viewStore.detail)
                    shelfSection(viewStore)
                    introSection(viewStore.detail.intro)
                    infoSection(viewStore.detail)

                    Button {
                        isShowingChapterList = true
                    } label: {
                        Label("开始阅读", systemImage: "book.pages")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("书籍详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .navigationDestination(isPresented: $isShowingChapterList) {
                ChapterListView(
                    store: Store(
                        initialState: ChapterListFeature.State(
                            bookPath: viewStore.detail.bookPath,
                            bookTitle: viewStore.detail.title
                        )
                    ) {
                        ChapterListFeature()
                    },
                    downloadStore: downloadStore
                )
            }
            .task { viewStore.send(.onAppear) }
            .onChange(of: viewStore.lastAddedRow) { _, row in
                if let row {
                    onAddedToShelf(row)
                }
            }
            .onChange(of: viewStore.lastRemovedPath) { _, bookPath in
                if let bookPath {
                    onRemovedFromShelf(bookPath)
                }
            }
        }
    }

    // MARK: - 加入 / 移出书架

    /// 书架开关。按 `isOnShelf` 切换，两条分支都用 `controlSize(.large)` 拿到 44pt 触控目标。
    ///
    /// 视觉分工（§9 主次分明）：未加入时它是页面上一眼可见的**主按钮**；
    /// 已加入时退成次级按钮并把图标换成绿色 checkmark —— 状态一眼可辨，
    /// 文字仍写动作（§11：按钮标签用动词），避免「已加入」当按钮却看不出点了会怎样。
    private func shelfSection(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewStore.isOnShelf {
                Button {
                    removeFromShelf(viewStore)
                } label: {
                    shelfLabel(viewStore, title: "移出书架", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.green)
            } else {
                Button {
                    viewStore.send(.addRequested)
                } label: {
                    shelfLabel(viewStore, title: "加入书架", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if let notice = viewStore.shelfNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.large)
        .disabled(viewStore.isShelfBusy)
    }

    @ViewBuilder
    private func shelfLabel(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>,
        title: String,
        systemImage: String
    ) -> some View {
        if viewStore.isShelfBusy {
            ProgressView()
                .frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
    }

    private func removeFromShelf(
        _ viewStore: ViewStore<BookDetailFeature.State, BookDetailFeature.Action>
    ) {
        // 与书架编辑态的删除保持一致：先把这本书在下载队列里的任务取消掉，
        // 再删本地记录与已下载正文。
        downloadStore.send(.cancelBook(viewStore.detail.bookPath))
        viewStore.send(.removeRequested)
    }

    private func header(_ detail: BookDetail) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            AsyncImage(url: URL(string: detail.coverUrl)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(Color(.tertiarySystemBackground))
                        .overlay {
                            Image(systemName: "book.closed")
                                .foregroundStyle(.quaternary)
                        }
                }
            }
            .frame(width: 92, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(detail.title.isEmpty ? "暂无书名" : detail.title)
                    .font(.title3.bold())
                    .lineLimit(2)

                Text(detail.author.isEmpty ? "未知作者" : detail.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !detail.status.isEmpty {
                    Text(detail.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }

                if !detail.category.isEmpty {
                    Text(detail.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func introSection(_ intro: String) -> some View {
        if !intro.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("简介")
                    .font(.headline)

                Text(intro)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(isIntroExpanded ? nil : 4)

                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                        isIntroExpanded.toggle()
                    }
                } label: {
                    Text(isIntroExpanded ? "收起" : "展开")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoSection(_ detail: BookDetail) -> some View {
        VStack(spacing: 0) {
            DetailInfoRow(title: "字数", value: detail.wordCount)
            DetailInfoRow(title: "最新章节", value: detail.lastChapter)
            DetailInfoRow(title: "更新时间", value: detail.lastUpdated)
            DetailInfoRow(title: "标签", value: detail.tags.joined(separator: " · "))
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
    }
}

private struct DetailInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .leading)

            Text(value.isEmpty ? "暂无" : value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
