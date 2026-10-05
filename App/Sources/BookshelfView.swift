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

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
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
                        // 有数据（或加载失败但有旧数据）—— 正常列表
                        List(viewStore.rows) { row in
                            BookRow(row: row)
                                .listRowSeparator(.hidden)
                                .listRowInsets(.init(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        .listStyle(.plain)
                        .refreshable {
                            await viewStore.send(.onAppear).finish()
                        }
                    }
                }
                .navigationTitle("书架")
                .onAppear { viewStore.send(.onAppear) }
            }
        }
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
        .padding(.vertical, 4)
        .contentShape(Rectangle()) // 整行可点
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
    BookshelfView(store: store)
}
