import Dependencies
import NovelCore
import SwiftUI

/// 阅读页内搜索：只查本地已缓存正文。
struct ReaderSearchView: View {
    let bookPath: String
    let onSelect: (CachedSearchHit) -> Void

    @Dependency(\.cachedBookSearch) private var searchService
    @State private var query = ""
    @State private var results: [CachedSearchHit] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "搜索缓存正文" : "没有找到",
                        systemImage: "magnifyingglass",
                        description: Text("只搜索已经缓存或下载的章节。")
                    )
                } else {
                    ForEach(results) { hit in
                        Button {
                            onSelect(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.chapterName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(hit.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .searchable(text: $query, prompt: "搜索已缓存正文")
            .navigationTitle("全本搜索")
            .task(id: query) {
                let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    results = []
                    return
                }
                isLoading = true
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                results = await (try? searchService.search(bookPath, normalized)) ?? []
                isLoading = false
            }
        }
    }
}
