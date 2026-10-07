import ComposableArchitecture
import NovelCore
import SwiftUI

/// 目录页 —— 显示一本书的章节列表，点章进阅读页。
///
/// ## 导航链路
/// 书架（BookshelfView）→ 点书 → 本页（ChapterListView）
/// → 点章 → ReaderView(chapterPath:)
///
/// 数据来自本地目录快照（SwiftData），完全离线可用。
struct ChapterListView: View {
    let store: StoreOf<ChapterListFeature>

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            Group {
                if viewStore.isLoading && viewStore.chapters.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = viewStore.errorMessage, viewStore.chapters.isEmpty {
                    VStack(spacing: 12) {
                        Text("加载失败").font(.title3.bold())
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Button("重试") { viewStore.send(.onAppear) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewStore.chapters) { chapter in
                        NavigationLink {
                            ReaderView(chapterPath: chapter.path)
                        } label: {
                            ChapterRow(chapter: chapter)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(viewStore.bookTitle)
            .onAppear { viewStore.send(.onAppear) }
        }
    }
}

/// 目录一行：章节名 + 本地状态标记。
private struct ChapterRow: View {
    let chapter: ChapterItem

    var body: some View {
        HStack(spacing: 8) {
            Text("\(chapter.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Text(chapter.name)
                .font(.body)
                .lineLimit(1)

            Spacer()

            if chapter.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            } else if chapter.hasLocalText {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    let store = Store(
        initialState: ChapterListFeature.State(
            bookPath: "/1/1/",
            bookTitle: "示例书",
            chapters: [
                ChapterItem(number: 1, name: "第一章", path: "/1/1/1.html", hasLocalText: true, isDownloaded: false),
                ChapterItem(number: 2, name: "第二章", path: "/1/1/2.html", hasLocalText: false, isDownloaded: false),
                ChapterItem(number: 3, name: "第三章", path: "/1/1/3.html", hasLocalText: true, isDownloaded: true),
            ]
        )
    ) {
        ChapterListFeature()
    }
    NavigationStack {
        ChapterListView(store: store)
    }
}
