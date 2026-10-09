import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 搜索页 —— 输入关键词、展示结果、把书加入书架。
///
/// 本文件只负责展示与转发交互，搜索和落库逻辑都在 `SearchFeature` 内。
struct SearchView: View {
    let store: StoreOf<SearchFeature>
    let downloadStore: StoreOf<DownloadFeature>
    let onBookAdded: (ShelfRow) -> Void
    let onBookRemoved: (String) -> Void

    /// 详情页 push 目标。与书架页一致用**显式 push** 而不是 `NavigationLink`：
    /// `List` 行里的 `NavigationLink` 会把整行接管成跳转目标（行尾的「加入书架」
    /// 按钮因此被吞掉，这正是 B0-5「看不到按钮」的成因）。
    @State private var detailBook: Book?
    @State private var isShowingDetail = false

    init(
        store: StoreOf<SearchFeature>,
        downloadStore: StoreOf<DownloadFeature>,
        onBookAdded: @escaping (ShelfRow) -> Void = { _ in },
        onBookRemoved: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.downloadStore = downloadStore
        self.onBookAdded = onBookAdded
        self.onBookRemoved = onBookRemoved
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 0) {
                    searchBar(viewStore)
                    content(viewStore)
                }
                // U0-3：整页底色统一成设置页那种 `systemGroupedBackground`（浅色 #F2F2F7）。
                // 搜索栏、结果列表、加载 / 空 / 错误态都透出这一层，页面里不再有任何一块白底。
                .background(Color(.systemGroupedBackground))
                .navigationTitle("搜索")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    noticeBanner(viewStore)
                }
                .navigationDestination(isPresented: $isShowingDetail) {
                    if let book = detailBook {
                        BookDetailView(
                            book: book,
                            downloadStore: downloadStore,
                            onAddedToShelf: { row in
                                viewStore.send(.addSucceeded(row))
                                // 详情页加入也走同一条同步路径。这里直接回调一次是必要的：
                                // 「移出书架再当场加回来」时 `lastAddedRow` 没有变化，
                                // 上面那个 onChange 不会再触发。重复一次不会插重复行
                                // —— `BookshelfFeature.addSucceeded` 按 bookPath 去重。
                                onBookAdded(row)
                            },
                            onRemovedFromShelf: { bookPath in
                                viewStore.send(.removedFromShelf(bookPath: bookPath))
                                onBookRemoved(bookPath)
                            }
                        )
                    }
                }
                .onChange(of: viewStore.lastAddedRow) { _, row in
                    if let row {
                        onBookAdded(row)
                    }
                }
                .task(id: viewStore.notice) {
                    guard viewStore.notice != nil else { return }
                    try? await Task.sleep(for: .seconds(1.0))
                    guard !Task.isCancelled else { return }
                    viewStore.send(.noticeDismissed)
                }
            }
        }
    }

    private func searchBar(
        _ viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        HStack(spacing: 10) {
            TextField(
                "书名或作者",
                text: viewStore.binding(get: \.keyword, send: SearchFeature.Action.keywordChanged)
            )
            .textFieldStyle(.roundedBorder)
            .submitLabel(.search)
            .onSubmit { viewStore.send(.search) }

            Button {
                viewStore.send(.search)
            } label: {
                if viewStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewStore.isLoading || viewStore.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("搜索")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(
        _ viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        if viewStore.isLoading, viewStore.results.isEmpty {
            loadingView
        } else if let message = viewStore.errorMessage {
            errorView(message, viewStore: viewStore)
        } else if viewStore.results.isEmpty {
            emptyView(
                title: viewStore.submittedKeyword.isEmpty ? "尚未搜索" : "没有找到相关书籍",
                message: viewStore.submittedKeyword.isEmpty
                    ? "输入书名或作者后点击搜索。"
                    : "换个关键词再试一次。"
            )
        } else {
            resultsView(viewStore)
        }
    }

    private var loadingView: some View {
        ProgressView("搜索中…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(
        _ message: String,
        viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        ContentUnavailableView {
            Label("搜索失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                viewStore.send(.search)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "magnifyingglass")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultsView(
        _ viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        List {
            ForEach(viewStore.results) { book in
                SearchResultRow(
                    book: book,
                    isAdding: viewStore.addingPaths.contains(book.path),
                    isAdded: viewStore.addedPaths.contains(book.path),
                    onOpen: {
                        detailBook = book
                        isShowingDetail = true
                    },
                    onAdd: { viewStore.send(.addRequested(book)) }
                )
                .listRowInsets(.init(top: 6, leading: 16, bottom: 6, trailing: 16))
                // 行背景清掉：plain List 的行 / 滚动背景默认是 `systemBackground`
                // （浅色纯白），会把页面灰盖住，卡片之间的 6pt 间隙尤其明显。
                .listRowBackground(Color.clear)
            }

            if viewStore.hasMore {
                loadMoreRow(viewStore)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // 让 List 自己的滚动背景透出页面色（U0-3 的那层白就是它）。
        .scrollContentBackground(.hidden)
    }

    private func loadMoreRow(
        _ viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        HStack(spacing: 10) {
            if viewStore.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            }
            Button("加载更多") {
                viewStore.send(.loadMore)
            }
            .disabled(viewStore.isLoadingMore)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func noticeBanner(
        _ viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        if let notice = viewStore.notice {
            HStack(spacing: 12) {
                Text(notice)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    viewStore.send(.noticeDismissed)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

private struct SearchResultRow: View {
    let book: Book
    let isAdding: Bool
    let isAdded: Bool
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 🔴 整卡跳详情用 `Button` + 外层显式 push，不用 `NavigationLink`：
            // List 行里的 NavigationLink 会接管整行，行尾的「加入书架」会被一起吞掉。
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.tertiarySystemBackground))
                        .frame(width: 48, height: 64)
                        .overlay {
                            Image(systemName: "book.closed")
                                .foregroundStyle(.quaternary)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(1)

                        Text(book.author.isEmpty ? "未知作者" : book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            if !book.wordCount.isEmpty {
                                Text(book.wordCount)
                            }
                            if !book.lastChapter.isEmpty {
                                Text(book.lastChapter)
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            // 强调层贴「打开详情」那块区域的轮廓；行尾「加入书架」是独立控件，不跟着变暗。
            .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 8))))

            shelfAction
        }
        .padding(12)
        .contentShape(Rectangle())
        // U0-3：与页面同色（用户要求统一成设置页的 `systemGroupedBackground`）。
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 「加入书架」入口。
    ///
    /// 未加入 = 带文字的次级按钮（`bordered`），命中区按 HIG 补到 44pt；
    /// 已加入 = 绿色 checkmark + 文字状态，一眼可辨，且不再重复发加书请求。
    @ViewBuilder
    private var shelfAction: some View {
        if isAdded {
            Label("已加入", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
                .frame(minHeight: 44)
                .accessibilityLabel("已在书架")
        } else {
            Button(action: onAdd) {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minHeight: 44)
                } else {
                    Label("加入书架", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        // 命中区补到 44pt：`.frame` 必须落在 label 上，
                        // 套在 Button 外面只是撑开布局，不会扩大真正的点击区域。
                        .frame(minHeight: 44)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isAdding)
            .accessibilityLabel("加入书架：\(book.title)")
        }
    }
}

// MARK: - Preview

#Preview {
    let store = Store(
        initialState: SearchFeature.State(
            keyword: "示例",
            submittedKeyword: "示例",
            results: [
                Book(path: "/1/1/", title: "示例书"),
                Book(path: "/1/2/", title: "另一本书"),
            ]
        )
    ) {
        SearchFeature()
    }
    SearchView(
        store: store,
        downloadStore: Store(initialState: DownloadFeature.State()) {
            DownloadFeature()
        }
    )
}
