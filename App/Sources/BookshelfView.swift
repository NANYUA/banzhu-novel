import ComposableArchitecture
import NovelCore
import SwiftUI

/// 书架列表（docs/03 §二 · §三，D15 = SwiftUI List）。
///
/// ## 与 Reducer 的分工
/// 本文件**只管展示和用户交互**，不碰任何业务逻辑。
/// 所有状态变化都通过 `store.send(...)` 走 `BookshelfFeature`，
/// 测试可以单独跑 reducer（不启动界面），也可以单独跑本 View（注入内存 store）。
///
/// ## 为什么用 WithViewStore 而不是 store.state / store.foo
/// `store.state` 和动态成员都要求 `State: ObservableState`（`@ObservableState` 宏）。
/// 但宏插件在 Xcode 16.4 的 xcodebuild 下跑不起来（本项目因此手写 Reducer 协议）。
/// `WithViewStore` 是 TCA 的传统观察方式，走 Combine，不依赖任何宏 ——
/// 在「宏在 CI 上不可靠」的前提下这是唯一稳定的观察路径。
///
/// ## 行布局
/// ```
/// ┌────────┐  书名
/// │        │  作者
/// │  封面  │  上次读到：…
/// │        │  最新章节：…
/// └────────┘          [未读 N 章]
/// ```
struct BookshelfView: View {
    let store: StoreOf<BookshelfFeature>
    let downloadStore: StoreOf<DownloadFeature>

    @State private var isShowingNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var renamingGroup: ShelfGroupSnapshot?
    @State private var renameGroupName = ""
    @State private var isConfirmingDelete = false
    /// 详情页目标。用显式 push 而不是 `NavigationLink`：见 `rowContent` 的注释。
    @State private var detailRow: ShelfRow?
    @State private var isShowingDetail = false
    /// 最近一次长按时间：用来挡掉长按抬手时 Button 多触发的那次点击。
    @State private var lastLongPressAt: Date?

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                VStack(spacing: 0) {
                    groupBar(viewStore)

                    ZStack {
                        if viewStore.isLoading, viewStore.rows.isEmpty {
                            // 首次加载中，还没数据也不确定是否失败
                            ProgressView("加载中…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let message = viewStore.errorMessage, viewStore.rows.isEmpty {
                            // 加载失败 + 无数据 → 显示错误 + 重试
                            VStack(spacing: 16) {
                                Text("加载失败")
                                    .font(.title3.bold())
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("重试") {
                                    viewStore.send(.onAppear)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            shelfList(viewStore)
                        }
                    }
                }
                .navigationTitle("书架")
                .onAppear { viewStore.send(.onAppear) }
                .navigationDestination(isPresented: $isShowingDetail) {
                    if let row = detailRow {
                        BookDetailView(
                            bookPath: row.bookPath,
                            title: row.title,
                            downloadStore: downloadStore
                        )
                    }
                }
                .toolbar {
                    toolbarContent(viewStore)
                }
                .alert("新建分组", isPresented: $isShowingNewGroupAlert) {
                    TextField("分组名", text: $newGroupName)
                    Button("创建") {
                        viewStore.send(.createGroup(newGroupName))
                        newGroupName = ""
                    }
                    Button("取消", role: .cancel) {
                        newGroupName = ""
                    }
                }
                .alert(
                    "重命名分组",
                    isPresented: Binding(
                        get: { renamingGroup != nil },
                        set: {
                            if !$0 {
                                renamingGroup = nil
                            }
                        }
                    )
                ) {
                    TextField("分组名", text: $renameGroupName)
                    Button("保存") {
                        if let group = renamingGroup {
                            viewStore.send(.renameGroup(group.id, renameGroupName))
                        }
                        renamingGroup = nil
                        renameGroupName = ""
                    }
                    Button("取消", role: .cancel) {
                        renamingGroup = nil
                        renameGroupName = ""
                    }
                }
                .confirmationDialog(
                    "删除选中的 \(viewStore.selectedBookPaths.count) 本书？",
                    isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        for path in viewStore.selectedBookPaths {
                            downloadStore.send(.cancelBook(path))
                        }
                        viewStore.send(.deleteSelectedBooks)
                    }
                    Button("取消", role: .cancel) {}
                }
                .onChange(of: viewStore.pendingDownloadRequests) { _, requests in
                    guard !requests.isEmpty else { return }
                    downloadStore.send(.enqueue(requests))
                    viewStore.send(.batchDownloadConsumed)
                }
            }
        }
    }
}

// MARK: - 分组栏

private extension BookshelfView {
    func groupBar(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        VStack(spacing: 0) {
            groupChips(viewStore)

            if let notice = viewStore.groupNotice {
                groupNotice(notice, viewStore: viewStore)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func groupChips(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                GroupChip(
                    title: "全部",
                    isSelected: viewStore.selectedGroupID == nil
                ) {
                    viewStore.send(.groupSelected(nil))
                }

                ForEach(viewStore.groups) { group in
                    GroupChip(
                        title: group.name,
                        isSelected: viewStore.selectedGroupID == group.id
                    ) {
                        viewStore.send(.groupSelected(group.id))
                    }
                    .contextMenu {
                        Button("重命名") {
                            renamingGroup = group
                            renameGroupName = group.name
                        }
                        Button("删除", role: .destructive) {
                            viewStore.send(.deleteGroup(group.id))
                        }
                    }
                }

                Button {
                    isShowingNewGroupAlert = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .accessibilityLabel("新建分组")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func groupNotice(
        _ notice: String,
        viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(notice)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewStore.send(.groupNoticeDismissed)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ToolbarContentBuilder
    func toolbarContent(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some ToolbarContent {
        if viewStore.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") {
                    viewStore.send(.editModeChanged(false))
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        viewStore.send(.downloadSelectedBooks)
                    } label: {
                        Label("整本下载", systemImage: "arrow.down.circle")
                    }

                    Menu("移入分组") {
                        Button("未分组") {
                            viewStore.send(.assignSelectedBooks(nil))
                        }
                        ForEach(viewStore.groups) { group in
                            Button(group.name) {
                                viewStore.send(.assignSelectedBooks(group.id))
                            }
                        }
                    }

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(viewStore.selectedBookPaths.isEmpty)
                .accessibilityLabel("批量操作")
            }
        }
    }
}

// MARK: - 列表

private extension BookshelfView {
    func shelfList(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        List(viewStore.visibleRows) { row in
            rowContent(row, viewStore: viewStore)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
        .listStyle(.plain)
        .refreshable {
            await viewStore.send(.onAppear).finish()
        }
    }

    @ViewBuilder
    private func rowContent(
        _ row: ShelfRow,
        viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        if viewStore.isEditing {
            let isSelected = viewStore.selectedBookPaths.contains(row.bookPath)
            Button {
                viewStore.send(.selectionToggled(row.bookPath))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    BookRow(row: row)
                }
            }
            .buttonStyle(PressableCardButtonStyle())
        } else {
            // 🔴 这里刻意不用 NavigationLink：它的点击手势会和长按手势抢识别，
            // 结果「点书进不去详情」（长按进编辑是既有交互，不能砍）。
            // 用 Button 拿到按下反馈（HIG：按下即反馈），长按用 simultaneousGesture
            // 并行识别；长按抬手时 Button 也会触发一次 action，用时间戳挡掉。
            Button {
                guard !isLongPressSuppressed else { return }
                detailRow = row
                isShowingDetail = true
            } label: {
                BookRow(row: row)
            }
            .buttonStyle(PressableCardButtonStyle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    lastLongPressAt = Date()
                    viewStore.send(.editModeChanged(true))
                }
            )
        }
    }

    /// 长按抬手后 Button 也会收到一次 action，这里挡掉，避免「长按同时跳详情」。
    private var isLongPressSuppressed: Bool {
        guard let lastLongPressAt else { return false }
        return Date().timeIntervalSince(lastLongPressAt) < 0.4
    }
}

// MARK: - 分组胶囊

private struct GroupChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        isSelected ? Color.accentColor : Color(.tertiarySystemFill)
                    )
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(PressableCardButtonStyle(pressedScale: 0.96))
    }
}

// MARK: - 单行

private struct BookRow: View {
    let row: ShelfRow

    var body: some View {
        HStack(spacing: 12) {
            // 封面
            AsyncImage(url: URL(string: row.coverUrl)) { phase in
                switch phase {
                case .empty:
                    placeholder
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 60, height: 80)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(6)

            // 文字区
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(row.author.isEmpty ? "未知作者" : row.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let last = row.lastReadChapterName {
                    Text("上次读到：\(last)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let latest = row.latestChapterName {
                    Text("最新章节：\(latest)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 未读章数 badge
            if row.unreadCount > 0 {
                Text("\(row.unreadCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(.red, in: Circle())
            }
        }
        .padding(12)
        .contentShape(Rectangle()) // 整张卡片可点
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color(.tertiarySystemBackground))
            .overlay {
                Image(systemName: "book")
                    .font(.title3)
                    .foregroundStyle(.quaternary)
            }
    }
}

// MARK: - Preview

#Preview {
    let store = Store(initialState: BookshelfFeature.State(
        rows: [
            ShelfRow(
                bookPath: "/49/49034/",
                title: "楚香君游戏",
                author: "某某某",
                coverUrl: "",
                lastReadChapterName: "第七章 夜探皇宫",
                latestChapterName: "第九章 风云起",
                unreadCount: 12,
                lastReadAt: Date()
            ),
            ShelfRow(
                bookPath: "/49/49035/",
                title: "另一本书",
                author: "",
                coverUrl: "",
                lastReadChapterName: nil,
                latestChapterName: "第一章",
                unreadCount: 0,
                lastReadAt: nil
            ),
        ],
        isLoading: false,
        errorMessage: nil
    )) {
        BookshelfFeature()
    }
    let downloadStore = Store(initialState: DownloadFeature.State()) {
        DownloadFeature()
    }
    BookshelfView(store: store, downloadStore: downloadStore)
}
