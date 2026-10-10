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
                        // `insetGrouped` 只在分组首 / 末行给卡面圆角，强调层必须逐角跟随（见 `shape`）。
                        let isFirstHit = hit.id == results.first?.id
                        let isLastHit = hit.id == results.last?.id
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
                            // 左右内边距改由标签自己持有：下面 `listRowInsets` 水平归零后标签铺满
                            // 整张卡，强调层才能覆盖**含内边距在内的整行**（真机反馈「也没有覆盖
                            // 整个卡片」：原来只覆盖到内容区那一条）。
                            .padding(.horizontal, DesignTokens.Spacing.md)
                            .padding(.vertical, DesignTokens.Spacing.sm)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        // §9 按下反馈：`.plain` 按下时只把**标签内容**压暗 —— 真机反馈
                        // 「搜索结果字体有变灰效果（应该为卡片变色）」。换成项目既有的
                        // `PressableCardButtonStyle` 后，反馈变成按下瞬间铺一层可见强调层
                        // （`Color.primary.opacity(0.12)`，浅色压暗 / 深色提亮）+ 轻微缩放，
                        // 且它整条替换了 `.plain` ⇒ 不再有第二套「文字变灰」叠在上面。
                        // 强调层轮廓逐角跟随系统卡面圆角 —— 铺满整卡后若一律用直角，
                        // 分组首 / 末行就会在圆角外露出方角。
                        .buttonStyle(PressableCardButtonStyle(
                            pressedScale: 0.99,
                            shape: AnyShape(UnevenRoundedRectangle(
                                topLeadingRadius: isFirstHit ? DesignTokens.Radius.sm : 0,
                                bottomLeadingRadius: isLastHit ? DesignTokens.Radius.sm : 0,
                                bottomTrailingRadius: isLastHit ? DesignTokens.Radius.sm : 0,
                                topTrailingRadius: isFirstHit ? DesignTokens.Radius.sm : 0
                            ))
                        ))
                        // 水平也归零：标签铺满整张卡 ⇒ 强调层覆盖整行，行高与文字缩进都不变。
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        // 分隔线起点仍留在原内容缩进处（行内边距归零后它本来会跑到卡片边缘）。
                        .alignmentGuide(.listRowSeparatorLeading) { _ in DesignTokens.Spacing.md }
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
