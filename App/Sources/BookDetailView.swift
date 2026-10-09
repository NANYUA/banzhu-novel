import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

/// 书籍详情页。展示网站详情页字段，并作为进入目录/阅读的唯一入口。
struct BookDetailView: View {
    let store: StoreOf<BookDetailFeature>
    let downloadStore: StoreOf<DownloadFeature>

    @State private var isIntroExpanded = false
    @State private var isShowingChapterList = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(book: Book, downloadStore: StoreOf<DownloadFeature>) {
        self.downloadStore = downloadStore
        store = Store(initialState: BookDetailFeature.State(fallback: BookDetail(book: book))) {
            BookDetailFeature()
        }
    }

    init(bookPath: String, title: String, downloadStore: StoreOf<DownloadFeature>) {
        self.downloadStore = downloadStore
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
        }
    }

    private func header(_ detail: BookDetail) -> some View {
        HStack(alignment: .top, spacing: 14) {
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
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
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

                Button(isIntroExpanded ? "收起" : "展开") {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)) {
                        isIntroExpanded.toggle()
                    }
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
        .padding(.horizontal, 14)
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
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
