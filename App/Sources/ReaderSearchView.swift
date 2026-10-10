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
                            // 行内边距由标签自己持有（配合下面的 `listRowInsets`）：竖向
                            // `Spacing.sm`(12) 撑出 44pt 以上命中区，强调层才能覆盖**整行**。
                            .padding(.vertical, DesignTokens.Spacing.sm)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        // §9 按下反馈：`.plain` 按下时只把**标签内容**压暗 —— 真机反馈
                        // 「搜索结果字体有变灰效果（应该为卡片变色）」。换成项目既有的
                        // `PressableCardButtonStyle` 后，反馈变成按下瞬间铺一层可见强调层
                        // （`Color.primary.opacity(0.12)`，浅色压暗 / 深色提亮）+ 轻微缩放，
                        // 且它整条替换了 `.plain` ⇒ 不再有第二套「文字变灰」叠在上面。
                        // 圆角取 `Radius.sm`(12)：本行没有自绘卡面，轮廓是系统行背景；
                        // 强调层水平内缩 `Spacing.md`(16)、垂直不出本行 ⇒ 圆角不会露到行外。
                        .buttonStyle(PressableCardButtonStyle(
                            pressedScale: 0.99,
                            shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                        ))
                        // 竖向 0 + 水平 16（= `insetGrouped` 系统默认行内边距）：左右缩进与行高
                        // 都基本不变，只是把竖向内边距让给标签自己 ⇒ 强调层铺满整行高度。
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: DesignTokens.Spacing.md,
                            bottom: 0,
                            trailing: DesignTokens.Spacing.md
                        ))
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
