import NovelCore
import NovelEngine
import SwiftUI

// 搜索结果列表的**分页行**：页码标签 / 加载行 / 「没有更多了」。
//
// 与 `SearchView.swift` 拆开：那支文件已 330+ 行（SwiftLint `file_length` 红线 600），
// 分页这块的视觉口径自成一节（见下），单独成文更好定位。
//
// 视觉底稿：owner 逐条确认过 `ui-mockups/demos/02-page-separator.html`（页码标签 + 「没有更多了」）
// 与 `03-pullup-load.html`（加载行）—— 居中、弱色、`.footnote`（13/18）、上下 `Spacing.md`、
// **无按压反馈、不可点**。这里按底稿落地，但不搬底稿里那套自绘滚动容器：列表仍是 `List`。

// MARK: - 行模型

/// 列表的一行：`book` + 「这本书之前要不要插一行『第 N 页』」。
///
/// 把「哪一行是页首」算在视图层、而不是在 `ForEach` 里就地下标查询，
/// 是为了让 `ForEach` 直接吃 `Identifiable` 的行（下标 `ForEach` 在插入后容易出现行身份错配）。
struct SearchDisplayRow: Identifiable {
    let book: Book
    /// 这本书之前要显示的页码标签；`nil` = 不插（第 1 页的第一本书，或不是页首）。
    let pageLabel: Int?

    var id: String {
        book.path
    }

    /// 按「每页第一本书」把搜索结果摊成列表行。
    ///
    /// - `results`：去重后的全部已加载书。
    /// - `pageStarts`：每一页第一本书的**页码 + 下标**（`SearchFeature.State.pageStarts`）。
    ///   第 1 页恒为 `(1, 0)` ⇒ 它的页首**不出标签**（需求：列表开头直接就是第 1 页的书）。
    ///   其余各页取**记下来的页号**当标签 —— 不按下标推算：整页都是重复的那一页不记录，
    ///   推算会让它后面所有页的页码整体少 1。
    ///
    /// 与 `results.count` 对不上的下标（理论上不会出现）直接忽略，只影响标签、不影响书。
    static func rows(results: [Book], pageStarts: [SearchPageStart]) -> [SearchDisplayRow] {
        var labelByIndex: [Int: Int] = [:]
        for start in pageStarts {
            guard start.page > 1, results.indices.contains(start.index) else { continue }
            labelByIndex[start.index] = start.page
        }
        return results.enumerated().map { index, book in
            SearchDisplayRow(book: book, pageLabel: labelByIndex[index])
        }
    }
}

// MARK: - 行视图

/// 「第 N 页」：**纯文本**，无按钮语义、不可点、无按压反馈 —— owner 原话
/// 「没有按钮效果，只是提醒我下面的书是第几页的内容」。
struct SearchPageLabelRow: View {
    let page: Int

    var body: some View {
        Text("第 \(page) 页")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.md)
            // 纯视觉分隔标记，不占 VoiceOver 焦点（书本身已按顺序读出来）。
            .accessibilityHidden(true)
    }
}

/// 上拉到底时露出的加载行：转圈 + 文案，**没有按钮**。
///
/// 触发出现在这一行进入视野（`.onAppear`）时；重复触发由 reducer 的
/// `.loadMore` 守卫（`hasMore` / `isLoading` / `isLoadingMore`）兜住，视图层不另设防抖状态。
/// 松手后 `List` 回弹，这一行留在底部继续转，直到下一页追加进来或到底。
struct SearchLoadMoreRow: View {
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

/// 到底了：一行居中弱色的「没有更多了」（不是加载行、不显示转圈、不可点）。
struct SearchEndOfResultsRow: View {
    var body: some View {
        Text("没有更多了")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.lg)
            .accessibilityHidden(true)
    }
}

/// 加载下一页**失败**时的加载行：真按钮「加载失败，点一下重试」。
///
/// 与 `SearchLoadMoreRow` 的区别只有两点（其余排版逐值相同，避免两行观感不一致）：
/// - 可点，且用既有的 `PressableCardButtonStyle` 给按下反馈（不自造按压效果）；
/// - **没有** `.onAppear` 自动触发 —— 失败后如果还自动重发，弱网下会变成无限重试循环，
///   而且用户根本看不到「点一下重试」这个入口。重试只由这一次点击发起。
///
/// 幂等仍只靠 reducer 的 `.loadMore` 守卫：重试就是再发一次 `.loadMore`，
/// 视图层不另设防抖状态。
struct SearchLoadMoreRetryRow: View {
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            Text("加载失败，点一下重试")
                .font(.footnote)
                // 失败态用语义状态色（`AppTheme.statusDanger` = 负向状态），
                // 不用 `AppTheme.accent`：按 `AppTheme` 的分工，accent 管「可点的主操作」，
                // 状态色管「状态本身」—— 这里首先是「上一次加载失败了」这个状态。
                .foregroundStyle(AppTheme.statusDanger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.sm)
                // HIG：触控目标 ≥ 44×44pt。`.footnote`(18) + 上下 `Spacing.sm`(12) 只有 42 ⇒ 补到 44。
                .frame(minHeight: DesignTokens.Hit.minSize)
        }
        .buttonStyle(PressableCardButtonStyle())
        .accessibilityLabel("加载失败，点一下重试")
    }
}

/// 搜索列表里「行自己撑满整行」的那几种行的统一行样式。
///
/// - **行内边距全部归零**：竖向留白由行自己给（`Spacing.md`，同视觉底稿），横向不留 ——
///   文字 `frame(maxWidth: .infinity)` 居中的才是整行中心。
/// - **分隔线隐藏**：这三行不是内容行，画一条线会看起来像一本书。
/// - **行背景清掉**：List 默认铺 `systemBackground`（浅色纯白），会盖掉页面的分组灰。
///
/// 只给页码标签行 / 加载行 / 重试行 / 「没有更多了」用；结果卡片行有自己的边距与背景，不走这里。
struct SearchRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(.init())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    /// 见 `SearchRowChrome`。
    func searchRowChrome() -> some View {
        modifier(SearchRowChrome())
    }
}
