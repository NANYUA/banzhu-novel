import NovelCore
import NovelEngine
import SwiftUI

struct ExploreDisplayRow: Identifiable {
    let book: Book
    let pageLabel: Int?

    var id: String {
        book.path
    }

    static func rows(books: [Book], pageStarts: [ExplorePageStart]) -> [ExploreDisplayRow] {
        var labels: [Int: Int] = [:]
        for start in pageStarts where start.page > 1 && books.indices.contains(start.index) {
            labels[start.index] = start.page
        }
        return books.enumerated().map { index, book in
            ExploreDisplayRow(book: book, pageLabel: labels[index])
        }
    }
}

struct ExplorePageLabelRow: View {
    let page: Int

    var body: some View {
        Text("第 \(page) 页")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.md)
            .accessibilityHidden(true)
    }
}

struct ExploreLoadMoreRow: View {
    let isLoadingMore: Bool
    let onLoadMore: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(isLoadingMore ? "正在加载…" : "上拉加载下一页")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.md)
        .onAppear(perform: onLoadMore)
    }
}

struct ExploreLoadMoreRetryRow: View {
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            Text("加载失败，点一下重试")
                .font(.footnote)
                .foregroundStyle(AppTheme.statusDanger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .frame(minHeight: DesignTokens.Hit.minSize)
        }
        .buttonStyle(PressableCardButtonStyle())
        .accessibilityLabel("加载失败，点一下重试")
    }
}

struct ExploreEndOfResultsRow: View {
    var body: some View {
        Text("没有更多了")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.lg)
            .accessibilityHidden(true)
    }
}

struct ExploreRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(.init())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    func exploreRowChrome() -> some View {
        modifier(ExploreRowChrome())
    }
}
