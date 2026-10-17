import NovelCore
import SwiftUI

/// 「本地」页顶部的「本地导入」一段。
///
/// owner 2026-10-17 真机反馈：「本地导入的书籍也要出现在本地列表中」——
/// 导入的书没有任何 `DownloadTask`，只靠下载队列渲染就永远看不见。
/// 这里把 `LocalBooksLoader` 捞出来的本地书按队列书卡同款卡面渲染，单点直接进阅读页。
struct LocalImportBooksSection: View {
    let books: [LocalBookRow]
    /// 与下载队列同一个落点入口：`(bookPath, title)`。
    let onOpenBook: (String, String) -> Void

    var body: some View {
        Section {
            ForEach(books) { book in
                Button {
                    onOpenBook(book.bookPath, book.title)
                } label: {
                    row(book)
                }
                .buttonStyle(PressableCardButtonStyle())
                .downloadQueueCard()
            }
        } header: {
            Text("本地导入（\(books.count)）")
        } footer: {
            Text("由「导入书籍」加进来的 txt，全部章节都在本地，不需要联网。")
        }
    }

    private func row(_ book: LocalBookRow) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "doc.text.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(
                    AppTheme.Surface.inset,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xs)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle(book))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: DesignTokens.Hit.minSize)
        .contentShape(Rectangle())
    }

    private func subtitle(_ book: LocalBookRow) -> String {
        let progress = if let chapterName = book.lastReadChapterName, !chapterName.isEmpty {
            "读至 \(chapterName)"
        } else {
            "未读"
        }
        return "\(book.author.isEmpty ? "未知作者" : book.author) · 共 \(book.chapterCount) 章 · \(progress)"
    }
}
