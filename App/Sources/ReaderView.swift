import ComposableArchitecture
import NovelCore
import NovelPagination
import SwiftUI
import UIKit

/// 阅读页 —— 显示一章正文，支持左右滑动翻页。
///
/// ## 渲染方案（docs/04 路线 C 的「单 UITextView」变体）
/// 不建"每页一个 UITextView"的 UIScrollView —— 那是性能优化（提前渲染相邻页），
/// 本轮最小可用：**一个 UITextView 显示当前页**，手势触发 nextPage/prevPage，
/// reducer 算好 currentOffset 后 View 重渲染。等真机性能验证后再上 UIScrollView。
///
/// ## 数据流
/// `currentOffset`（字符偏移，不是页码）→ reducer 反查所在页 → View 取
/// `pages[pageIndex]` 的字符范围 `text[location..<location+length]` 渲染。
///
/// ## 分页度量注入
/// 创建 store 时用 `withDependencies` 注入真实 `TextKitMeasuring`（NovelPagination），
/// 替换 NovelCore 里的 Fake 占位 —— 这样真机上分页才是真实排版。
struct ReaderView: View {
    let store: StoreOf<ReaderFeature>

    /// 便捷构造：给定章节路径，创建带真实排版度量的阅读页 store。
    init(chapterPath: String) {
        self.store = Store(
            initialState: ReaderFeature.State(chapterPath: chapterPath)
        ) {
            ReaderFeature()
        } withDependencies: {
            // 注入真实排版度量（UIKit 实现，NovelCore 里的是 Fake 占位）
            $0.paginationService.paginate = { text, config in
                Paginator(measurer: TextKitMeasuring()).paginate(text: text, configuration: config)
            }
        }
    }

    /// 测试/嵌入用：直接接收外部 store（含 preview 等场景）。
    init(store: StoreOf<ReaderFeature>) {
        self.store = store
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            ZStack {
                if viewStore.isLoading && viewStore.text.isEmpty {
                    ProgressView("加载中…")
                } else if let message = viewStore.errorMessage, viewStore.text.isEmpty {
                    VStack(spacing: 12) {
                        Text("加载失败")
                            .font(.title3.bold())
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("重试") { viewStore.send(.loadChapter(viewStore.chapterPath)) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    PageTextView(
                        text: currentPageText(viewStore),
                        fontSize: viewStore.config.fontSize,
                        lineSpacing: viewStore.config.lineSpacing
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                let dx = value.translation.width
                                if dx < -30 {
                                    viewStore.send(.nextPage)
                                } else if dx > 30 {
                                    viewStore.send(.prevPage)
                                }
                            }
                    )
                }
            }
            .navigationTitle("")
            .task {
                viewStore.send(.loadChapter(viewStore.chapterPath))
            }
        }
    }

    /// 取当前页对应的文本片段。
    private func currentPageText(_ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>) -> String {
        let pages = viewStore.pages
        let offset = viewStore.currentOffset
        let text = viewStore.text

        guard !pages.isEmpty, !text.isEmpty else { return text }
        guard let page = pages.first(where: { offset >= $0.location, offset < $0.location + $0.length }) else {
            return text
        }
        let chars = Array(text)
        let start = min(page.location, chars.count)
        let end = min(page.location + page.length, chars.count)
        guard start < end else { return "" }
        return String(chars[start..<end])
    }
}

/// 单页 UITextView 包装（UIKit 承载，SwiftUI 里用 UIViewRepresentable）。
private struct PageTextView: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        textView.backgroundColor = .systemBackground
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        uiView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraphStyle,
                .foregroundColor: UIColor.label,
            ]
        )
    }
}
