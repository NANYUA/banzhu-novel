import ComposableArchitecture
import NovelCore
import NovelPagination
import SwiftUI
import UIKit

/// 阅读页 —— 显示一章正文，支持滑动 / 点击 / 滚动三种翻页方式。
///
/// ## 渲染方案（docs/04 路线 C 的「单 UITextView」变体）
/// 分页模式用单个 `UITextView` 显示当前页；滚动模式用同一个
/// `UITextView` 显示整章并监听滚动位置。
///
/// ## 数据流
/// `currentOffset`（字符偏移，不是页码）→ reducer 反查所在页 → View 取
/// `pages[pageIndex]` 的字符范围渲染。滚动模式则把滚动位置换算成字符偏移
/// 回写给 reducer，切换设置后仍能靠 offset 定位。
///
/// ## 分页度量注入
/// 创建 store 时用 `withDependencies` 注入真实 `TextKitMeasuring`（NovelPagination），
/// 替换 NovelCore 里的 Fake 占位 —— 这样真机上分页才是真实排版。
struct ReaderView: View {
    let store: StoreOf<ReaderFeature>

    @State private var isShowingSettings = false

    /// 便捷构造：给定章节路径，创建带真实排版度量的阅读页 store。
    init(chapterPath: String) {
        store = Store(
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
            GeometryReader { geometry in
                ZStack {
                    backgroundColor(for: viewStore.config)
                        .ignoresSafeArea()

                    readerContent(viewStore, availableWidth: geometry.size.width)
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .accessibilityLabel("阅读设置")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                ReaderSettingsView(configuration: viewStore.config) { newConfiguration in
                    viewStore.send(.configChanged(newConfiguration))
                }
            }
            .preferredColorScheme(viewStore.config.appearanceMode.preferredColorScheme)
            .task {
                viewStore.send(.loadChapter(viewStore.chapterPath))
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func readerContent(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) -> some View {
        if viewStore.isLoading, viewStore.text.isEmpty {
            ProgressView("加载中…")
        } else if let message = viewStore.errorMessage, viewStore.text.isEmpty {
            VStack(spacing: 12) {
                Text("加载失败")
                    .font(.title3.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    viewStore.send(.loadChapter(viewStore.chapterPath))
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            pageContent(viewStore, availableWidth: availableWidth)
        }
    }

    private func pageContent(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) -> some View {
        let configuration = viewStore.config
        let displayText = configuration.pageTurnMode == .scroll
            ? viewStore.text
            : currentPageText(viewStore)

        let page = ZStack {
            PageTextView(
                text: displayText,
                offset: viewStore.currentOffset,
                configuration: configuration,
                onOffsetChange: { offset in
                    viewStore.send(.jumpToOffset(offset))
                }
            )
            .allowsHitTesting(configuration.pageTurnMode == .scroll)
            .id(pageIdentity(viewStore))
            .transition(pageTransition(for: configuration.pageTurnAnimation))
        }
        .contentShape(Rectangle())
        .animation(
            configuration.pageTurnMode == .scroll
                ? nil
                : pageAnimation(for: configuration.pageTurnAnimation),
            value: viewStore.currentPageIndex
        )

        return readerGesture(page, viewStore: viewStore, availableWidth: availableWidth)
    }

    // MARK: - 手势

    @ViewBuilder
    private func readerGesture(
        _ content: some View,
        viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        availableWidth: CGFloat
    ) -> some View {
        switch viewStore.config.pageTurnMode {
        case .slide:
            content.gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        guard abs(horizontal) > abs(vertical) else { return }
                        if horizontal < -30 {
                            viewStore.send(.nextPage)
                        } else if horizontal > 30 {
                            viewStore.send(.prevPage)
                        }
                    }
            )

        case .tap:
            content.gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        if value.location.x < availableWidth / 2 {
                            viewStore.send(.prevPage)
                        } else {
                            viewStore.send(.nextPage)
                        }
                    }
            )

        case .scroll:
            content
        }
    }

    // MARK: - 外观

    private func backgroundColor(for configuration: PaginationConfiguration) -> Color {
        Color(uiColor: configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor
        ))
    }

    private func pageIdentity(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        guard viewStore.config.pageTurnMode != .scroll else { return "scroll" }
        return "page-\(viewStore.currentPageIndex)"
    }

    private func pageTransition(for animation: PageTurnAnimation) -> AnyTransition {
        switch animation {
        case .none:
            .identity
        case .cover:
            .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        case .curl:
            .asymmetric(
                insertion: .scale(scale: 0.94, anchor: .trailing).combined(with: .opacity),
                removal: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity)
            )
        }
    }

    private func pageAnimation(for animation: PageTurnAnimation) -> Animation? {
        switch animation {
        case .none:
            nil
        case .cover:
            .easeInOut(duration: 0.2)
        case .curl:
            .easeInOut(duration: 0.3)
        }
    }

    // MARK: - 分页定位

    /// 取当前页对应的文本片段。
    private func currentPageText(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        let pages = viewStore.pages
        let offset = viewStore.currentOffset
        let text = viewStore.text

        guard !pages.isEmpty, !text.isEmpty else { return text }
        guard let page = pages.first(where: { offset >= $0.location && offset < $0.location + $0.length }) else {
            return text
        }
        let chars = Array(text)
        let start = min(page.location, chars.count)
        let end = min(page.location + page.length, chars.count)
        guard start < end else { return "" }
        return String(chars[start ..< end])
    }
}

/// 单页 / 整章 `UITextView` 包装（UIKit 承载，SwiftUI 里用 `UIViewRepresentable`）。
///
/// 分页模式下只渲染当前页并关闭滚动；滚动模式下渲染整章并监听滚动位置。
private struct PageTextView: UIViewRepresentable {
    let text: String
    let offset: Int
    let configuration: PaginationConfiguration
    let onOffsetChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = true
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self

        let contentChanged = context.coordinator.appliedText != text
            || context.coordinator.appliedConfiguration != configuration
        guard contentChanged else { return }

        context.coordinator.appliedText = text
        context.coordinator.appliedConfiguration = configuration

        uiView.isScrollEnabled = configuration.pageTurnMode == .scroll
        uiView.textContainerInset = UIEdgeInsets(
            top: configuration.inset.top,
            left: configuration.inset.leading,
            bottom: configuration.inset.bottom,
            right: configuration.inset.trailing
        )
        uiView.backgroundColor = configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor
        )
        uiView.attributedText = makeAttributedString()

        if configuration.pageTurnMode == .scroll {
            context.coordinator.scrollToOffset(offset, in: uiView)
        }
    }

    private func makeAttributedString() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = configuration.lineSpacing
        paragraphStyle.paragraphSpacing = configuration.paragraphSpacing
        paragraphStyle.firstLineHeadIndent = configuration.firstLineHeadIndent

        let backgroundColor = configuration.backgroundStyle.uiColor(
            custom: configuration.customBackgroundColor
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ReadingFontFactory.makeFont(configuration: configuration),
            .paragraphStyle: paragraphStyle,
            .kern: configuration.characterSpacing,
            .foregroundColor: configuration.textColorMode.uiColor(
                on: backgroundColor,
                custom: configuration.customTextColor
            ),
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PageTextView
        var appliedText: String?
        var appliedConfiguration: PaginationConfiguration?

        init(parent: PageTextView) {
            self.parent = parent
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            reportOffset(scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportOffset(scrollView)
        }

        func scrollToOffset(_ offset: Int, in textView: UITextView) {
            let location = utf16Offset(for: offset, in: textView.text)
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }

        private func reportOffset(_ scrollView: UIScrollView) {
            guard parent.configuration.pageTurnMode == .scroll,
                  let textView = scrollView as? UITextView
            else {
                return
            }

            let visibleTop = CGPoint(
                x: textView.textContainerInset.left + textView.textContainer.lineFragmentPadding,
                y: scrollView.contentOffset.y + textView.textContainerInset.top
            )
            let utf16Offset = textView.layoutManager.characterIndex(
                for: visibleTop,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            parent.onOffsetChange(characterOffset(fromUTF16: utf16Offset, in: textView.text))
        }

        private func characterOffset(fromUTF16 offset: Int, in text: String) -> Int {
            guard let utf16Index = text.utf16.index(
                text.utf16.startIndex,
                offsetBy: offset,
                limitedBy: text.utf16.endIndex
            ),
                let index = String.Index(utf16Index, within: text)
            else {
                return 0
            }
            return text.distance(from: text.startIndex, to: index)
        }

        private func utf16Offset(for characterOffset: Int, in text: String) -> Int {
            let clamped = min(max(characterOffset, 0), text.count)
            guard let index = text.index(text.startIndex, offsetBy: clamped, limitedBy: text.endIndex),
                  let utf16Index = index.samePosition(in: text.utf16)
            else {
                return text.utf16.count
            }
            return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
        }
    }
}
