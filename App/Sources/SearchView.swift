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

    init(
        store: StoreOf<SearchFeature>,
        downloadStore: StoreOf<DownloadFeature>,
        onBookAdded: @escaping (ShelfRow) -> Void = { _ in }
    ) {
        self.store = store
        self.downloadStore = downloadStore
        self.onBookAdded = onBookAdded
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 0) {
                    searchBar(viewStore)
                    content(viewStore)
                }
                .navigationTitle("搜索")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    noticeBanner(viewStore)
                }
                .onChange(of: viewStore.lastAddedRow) { _, row in
                    if let row {
                        onBookAdded(row)
                    }
                }
                .task(id: viewStore.notice) {
                    guard viewStore.notice != nil else { return }
                    try? await Task.sleep(for: .seconds(2.5))
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
            emptyView(title: viewStore.submittedKeyword.isEmpty ? "尚未搜索" : "没有找到相关书籍")
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
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("搜索失败")
                .font(.title3.bold())
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                viewStore.send(.search)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
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
                    downloadStore: downloadStore
                ) {
                    viewStore.send(.addRequested(book))
                }
                .listRowInsets(.init(top: 6, leading: 16, bottom: 6, trailing: 16))
            }

            if viewStore.hasMore {
                loadMoreRow(viewStore)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
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
    let downloadStore: StoreOf<DownloadFeature>
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                BookDetailView(book: book, downloadStore: downloadStore)
            } label: {
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
                            .font(.body.bold())
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
            .buttonStyle(PressableCardButtonStyle())

            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("已加入书架")
            } else {
                Button(action: onAdd) {
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.title3)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isAdding)
                .accessibilityLabel("加入书架：\(book.title)")
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
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
