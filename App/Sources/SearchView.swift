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
    let onBookRemoved: (String) -> Void

    /// 详情页 push 目标。与书架页一致用**显式 push** 而不是 `NavigationLink`：
    /// `List` 行里的 `NavigationLink` 会把整行接管成跳转目标（行尾的「加入书架」
    /// 按钮因此被吞掉，这正是 B0-5「看不到按钮」的成因）。
    @State private var detailBook: Book?
    @State private var isShowingDetail = false

    init(
        store: StoreOf<SearchFeature>,
        downloadStore: StoreOf<DownloadFeature>,
        onBookAdded: @escaping (ShelfRow) -> Void = { _ in },
        onBookRemoved: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.downloadStore = downloadStore
        self.onBookAdded = onBookAdded
        self.onBookRemoved = onBookRemoved
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                content(viewStore)
                    // U1-1：页面底 = 浅色分组灰（`AppTheme.Surface.page`），卡面 = 白（`AppTheme.Surface.card`），
                    // 两者形成一级层次。搜索结果卡的白色由 `SearchResultRow` 自己画。
                    .background(AppTheme.Surface.page)
                    .navigationTitle("搜索")
                    // 底栏可见性的**唯一所有者**就是每个 tab 根视图（同 `BookshelfView`），由状态驱动。
                    // push 详情期间根的状态是 `.hidden` ⇒ 详情页没有底栏；回到根时翻回 `.visible`
                    // ⇒ 底栏可靠恢复。详情页自己不再声明底栏，所以「根视图声明胜出」与
                    // 「最上层声明胜出」两种偏好解析模型下行为一致。
                    .toolbar(isShowingDetail ? .hidden : .visible, for: .tabBar)
                    // 底栏**背景**同样由根视图声明为「始终可见」：iOS 15+ 的底栏有 scroll-edge 外观，
                    // 本页的首屏（尚未搜索 / 加载中 / 空态 / 错误态）与「结果不够长」的列表都没在滚动，
                    // 背景本来就是透明的 —— 真机「进搜索 tab 底栏偶尔变透明」就是它。
                    // 与上面的可见性同一层声明；阅读页整条底栏是 `.hidden`，专注模式不受影响。
                    .toolbarBackground(.visible, for: .tabBar)
                    // §1 一致性：与同项目的 `ReaderSearchView` 统一到系统 `.searchable`
                    // 范式，自绘搜索栏（TextField + 搜索按钮）已删除。
                    // 提交语义不变，仍是同一个 `.search` action。
                    //
                    // 用 `.always` 而不是默认的 `.automatic`：本页的空 / 加载 / 错误态
                    // 都不是可滚动视图，`.automatic` 靠滚动才把搜索框抽屉拉出来，
                    // 在「尚未搜索」的首屏上搜索框会不可见 —— 搜索页上这是致命缺陷。
                    .searchable(
                        text: viewStore.binding(
                            get: \.keyword,
                            send: SearchFeature.Action.keywordChanged
                        ),
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "书名或作者"
                    )
                    .onSubmit(of: .search) {
                        viewStore.send(.search)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        noticeBanner(viewStore)
                    }
                    .navigationDestination(isPresented: $isShowingDetail) {
                        if let book = detailBook {
                            BookDetailView(
                                book: book,
                                downloadStore: downloadStore,
                                onAddedToShelf: { row in
                                    viewStore.send(.addSucceeded(row))
                                    // 详情页加入也走同一条同步路径。这里直接回调一次是必要的：
                                    // 「移出书架再当场加回来」时 `lastAddedRow` 没有变化，
                                    // 上面那个 onChange 不会再触发。重复一次不会插重复行
                                    // —— `BookshelfFeature.addSucceeded` 按 bookPath 去重。
                                    onBookAdded(row)
                                },
                                onRemovedFromShelf: { bookPath in
                                    viewStore.send(.removedFromShelf(bookPath: bookPath))
                                    onBookRemoved(bookPath)
                                }
                            )
                        }
                    }
                    .onChange(of: viewStore.lastAddedRow) { _, row in
                        if let row {
                            onBookAdded(row)
                        }
                    }
                    .task(id: viewStore.notice) {
                        guard viewStore.notice != nil else { return }
                        try? await Task.sleep(for: .seconds(1.0))
                        guard !Task.isCancelled else { return }
                        viewStore.send(.noticeDismissed)
                    }
            }
        }
    }

    @ViewBuilder
    private func content(
        _ viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        // 去掉搜索栏后，搜索按钮上那圈 spinner 也没了；把 isLoading 提到最前面，
        // 保证「改关键词再搜」时也有可见反馈（否则旧结果原样留着，看起来像没点中）。
        if viewStore.isLoading {
            loadingView
        } else if let message = viewStore.errorMessage {
            errorView(message, viewStore: viewStore)
        } else if viewStore.results.isEmpty {
            emptyView(
                title: viewStore.submittedKeyword.isEmpty ? "尚未搜索" : "没有找到相关书籍",
                message: viewStore.submittedKeyword.isEmpty
                    ? "在搜索框输入书名或作者，然后按键盘上的搜索。"
                    : "换个关键词再试一次。"
            )
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
        ContentUnavailableView {
            Label("搜索失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                viewStore.send(.search)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "magnifyingglass")
        } description: {
            Text(message)
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
                    onOpen: {
                        detailBook = book
                        isShowingDetail = true
                    },
                    onAdd: { viewStore.send(.addRequested(book)) }
                )
                .listRowInsets(
                    .init(
                        top: DesignTokens.Spacing.xs,
                        leading: DesignTokens.Spacing.md,
                        bottom: DesignTokens.Spacing.xs,
                        trailing: DesignTokens.Spacing.md
                    )
                )
                .listRowSeparator(.hidden)
                // 行背景清掉：卡面颜色由 `SearchResultRow` 自己画（`AppTheme.Surface.card`），
                // 这里再铺一层 List 默认的 `systemBackground`（浅色纯白）会把卡片之间的
                // 间隙也涂白，卡片就与页面分不出层次了。
                .listRowBackground(Color.clear)
            }

            if viewStore.hasMore {
                loadMoreRow(viewStore)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // 让 List 自己的滚动背景透出页面分组灰。
        .scrollContentBackground(.hidden)
    }

    private func loadMoreRow(
        _ viewStore: ViewStore<SearchFeature.State, SearchFeature.Action>
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if viewStore.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                viewStore.send(.loadMore)
            } label: {
                Text("加载更多")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
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
            HStack(spacing: DesignTokens.Spacing.sm) {
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
                // §9 按下反馈：`.plain` 按下零反馈；强调层按 12pt 内缩贴图标自身的圆，
                // 不铺成 44pt 大圆盘（命中区仍由 label 的 44×44 + `.contentShape` 提供）。
                .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Circle().inset(by: DesignTokens.Spacing.sm))))
                .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.xs)
        }
    }
}

private struct SearchResultRow: View {
    let book: Book
    let isAdding: Bool
    let isAdded: Bool
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // 🔴 整卡跳详情用 `Button` + 外层显式 push，不用 `NavigationLink`：
            // List 行里的 NavigationLink 会接管整行，行尾的「加入书架」会被一起吞掉。
            Button(action: onOpen) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                        .fill(AppTheme.Surface.inset)
                        .frame(width: 48, height: 64)
                        .overlay {
                            Image(systemName: "book.closed")
                                .foregroundStyle(.quaternary)
                        }

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(1)

                        Text(book.author.isEmpty ? "未知作者" : book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: DesignTokens.Spacing.xs) {
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
            // 强调层贴「打开详情」那块区域的轮廓；行尾「加入书架」是独立控件，不跟着变暗。
            .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))))

            // 两个独立触控目标之间的发丝分隔线（系统 `Divider()`，不自算 1px）：
            // 左边整块进详情、右边「加入书架」，这条线让「一块卡里有两个可点区域」一眼可读。
            Divider()

            shelfAction
        }
        .padding(DesignTokens.Spacing.sm)
        .contentShape(Rectangle())
        // U1-1：卡面 = 白（`AppTheme.Surface.card`），压在页面的分组灰底上形成一级层次；
        // 圆角统一 `DesignTokens.Radius.sm` = 12。
        .background(
            AppTheme.Surface.card,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        )
    }

    /// 「加入书架」入口。
    ///
    /// 未加入 = 带文字的次级按钮（`bordered`），命中区按 HIG 补到 44pt；
    /// 已加入 = 绿色 checkmark + 文字状态，一眼可辨，且不再重复发加书请求。
    @ViewBuilder
    private var shelfAction: some View {
        if isAdded {
            Label("已加入", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
                .frame(minHeight: 44)
                .accessibilityLabel("已在书架")
        } else {
            Button(action: onAdd) {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minHeight: 44)
                } else {
                    Label("加入书架", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        // 命中区补到 44pt：`.frame` 必须落在 label 上，
                        // 套在 Button 外面只是撑开布局，不会扩大真正的点击区域。
                        .frame(minHeight: 44)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isAdding)
            .accessibilityLabel("加入书架：\(book.title)")
        }
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
