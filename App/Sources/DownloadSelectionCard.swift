import SwiftUI

/// 选择模式下的**操作卡片**：与总进度卡片**同位置、同尺寸**交替展示（U11）。
///
/// ## 为什么占的是进度卡片的位置
/// owner 口径：「长按选择就是让选择卡片使用进度卡片的位置，两张卡片在一个位置交替展示」。
/// 原先四个操作悬在 `List` 上方（`DownloadSelectionBar`，`.regularMaterial` 分层），
/// 触发选择时总进度那块还留在列表里 —— 两套卡片语言并存。现在两者在
/// `DownloadQueueView.pinnedHeader` 的**同一个 `Group` 分支**里二选一
/// （`if isSelecting { 本卡 } else { 总进度卡 }`），尺寸统一到
/// `DownloadCardMetrics.contentHeight`（= 书卡内容区高度）。
///
/// ## 四项横排、等宽平分
/// owner 口径：「保持从左到右的四个选项」⇒ `HStack` 一行四项、每项 `.frame(maxWidth: .infinity)`；
/// 不做 2×2、不做竖排。顺序固定：全选 / 暂停下载 / 删除下载 / 重试失败。
///
/// ## 图标与颜色
/// 图标一律 SF Symbols（不用 emoji）：`checkmark.circle` / `pause.fill` / `trash` /
/// `arrow.clockwise`。颜色只引用令牌：全选与暂停下载 = `AppTheme.accent`，
/// 删除下载 = `AppTheme.statusDanger`，重试失败 = `AppTheme.statusAttention`。
///
/// ## 禁用态的口径（照抄被它取代的 `DownloadSelectionBar`）
/// 那条批量栏对不可用项的做法是**照常渲染 + `.disabled(true)` + 把颜色换成 `Color.secondary`**
/// （删除前的 `DownloadSelectionBar.action(_:_:tint:enabled:perform:)`），**不是**不渲染。
/// 本卡沿用同一口径：四项始终都在，不可用时图标与标题一起换次级色、`.disabled(true)`
/// 挡住点击，并让 VoiceOver 把「不可用」读出来。
///
/// ⚠️ 这里**不引入**「禁用不透明度」这类新常量：全仓现有的置灰手法就是换 `Color.secondary`，
/// 再定义一个同值常量等于开了第二个真相源（阅读页那个 `disabledOpacity` 是
/// `ReaderView+Chrome.swift` 里 `private enum` 的成员，本文件也取不到）。
struct DownloadSelectionCard: View {
    /// 已选书数（`selectedBookPaths.count`）。
    let selectedBookCount: Int
    /// 队列里的书总数（`bookPaths.count`）。
    let totalBookCount: Int
    /// 队列里的书是否已全选（`areAllBooksSelected`）：决定第一项是「全选」还是「取消全选」。
    let isAllSelected: Bool
    /// 选中书里**会被暂停**的书数（有排队 / 进行中任务的书，与 reducer 的 `affected` 同判据）。
    let pausableBookCount: Int
    /// 选中书里是否还有进行中的任务（`canPauseSelectedBooks`）。
    let canPause: Bool
    /// 选中书里**失败的任务数**（「重试失败」实际会重排的章节数，单位是章）。
    let retryableChapterCount: Int
    /// 选中书里是否还有失败任务（`canRetryFailedSelectedBooks`）。
    let canRetryFailed: Bool
    let onToggleSelectAll: () -> Void
    let onPause: () -> Void
    let onDelete: () -> Void
    let onRetryFailed: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            selectAllAction
            pauseAction
            deleteAction
            retryFailedAction
        }
        // 与总进度卡片、书卡同高：内容区 `contentHeight`(80) + 内边距 12×2 + `.downloadQueueCard()` 的 8×2。
        .frame(minHeight: DownloadCardMetrics.contentHeight)
        .padding(DesignTokens.Spacing.sm)
        .downloadQueueCard()
    }
}

private extension DownloadSelectionCard {
    /// 全选 / 取消全选。已全选时标题与图标一起切换 —— `toggleSelectAllBooks` 是**切换**语义
    /// （与书架编辑态一致），不切标题的话「点一下全选」在已全选时反而会清空选择。
    var selectAllAction: some View {
        action(
            DownloadSelectionActionItem(
                title: isAllSelected ? "取消全选" : "全选",
                systemImage: isAllSelected ? "checkmark.circle.fill" : "checkmark.circle",
                detail: "已选 \(selectedBookCount) / 共 \(totalBookCount) 本",
                tint: AppTheme.accent,
                enabled: true,
                accessibilityLabel: isAllSelected
                    ? "取消全选，已选 \(selectedBookCount) 本，共 \(totalBookCount) 本"
                    : "全选，已选 \(selectedBookCount) 本，共 \(totalBookCount) 本"
            ),
            perform: onToggleSelectAll
        )
    }

    var pauseAction: some View {
        action(
            DownloadSelectionActionItem(
                title: "暂停下载",
                systemImage: "pause.fill",
                detail: "\(pausableBookCount) 本",
                tint: AppTheme.accent,
                enabled: canPause,
                accessibilityLabel: "暂停下载，\(pausableBookCount) 本"
            ),
            perform: onPause
        )
    }

    /// 删除下载：破坏性操作，计数行点明删的是正文，无障碍文案再点明不可撤销。
    var deleteAction: some View {
        action(
            DownloadSelectionActionItem(
                title: "删除下载",
                systemImage: "trash",
                detail: "正文删除",
                tint: AppTheme.statusDanger,
                enabled: selectedBookCount > 0,
                accessibilityLabel: "删除下载，会删除已下载的正文，不可撤销"
            ),
            perform: onDelete
        )
    }

    var retryFailedAction: some View {
        action(
            DownloadSelectionActionItem(
                title: "重试失败",
                systemImage: "arrow.clockwise",
                detail: "\(retryableChapterCount) 章",
                tint: AppTheme.statusAttention,
                enabled: canRetryFailed,
                accessibilityLabel: "重试失败，\(retryableChapterCount) 章"
            ),
            perform: onRetryFailed
        )
    }

    /// 一项操作：38×38 图标块 + 标题 + 小计数行；整项是一个 `Button`（命中区约 70×80pt，≥ 44×44）。
    func action(
        _ item: DownloadSelectionActionItem,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                icon(item)

                Text(item.title)
                    // 自定义 ButtonStyle 不会自己变灰：不可用时与图标一起换次级色
                    // （不显式给就成了「看着能点却没反应」）。
                    .foregroundStyle(item.enabled ? Color.primary : Color.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // HIG §9：`.frame` 必须落在 label 上才真的撑开命中区（套在 Button 外面无效）。
            // `.frame(maxWidth: .infinity)` 让四项等宽平分整行。
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // 按下反馈复用既有样式（不另造第二个），强调层贴卡片自身的 12pt 圆角；
        // 缩放幅度 0.96 沿用被替换的那条批量操作栏（元素小于整卡，幅度略大于卡片默认的 0.98）。
        .buttonStyle(PressableCardButtonStyle(
            pressedScale: 0.96,
            shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        ))
        .disabled(!item.enabled)
        // 不可用时把「不可用」读出来（`.disabled` 只给 dimmed trait，文案更明确）。
        .accessibilityLabel(item.enabled ? item.accessibilityLabel : "\(item.accessibilityLabel)，不可用")
    }

    /// 38×38 图标块：底色 `Surface.inset`（卡面上的次级区块）、圆角走卡片令牌；不可用时图标换次级色。
    func icon(_ item: DownloadSelectionActionItem) -> some View {
        Image(systemName: item.systemImage)
            .font(.title3)
            // 自定义 ButtonStyle 不吃 `.tint`，颜色在这里显式给。
            .foregroundStyle(item.enabled ? item.tint : Color.secondary)
            .frame(width: DownloadCardMetrics.actionIconSize, height: DownloadCardMetrics.actionIconSize)
            .background(
                AppTheme.Surface.inset,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            )
    }
}

/// 选择卡片里一项操作的**内容**（图标 / 标题 / 计数 / 颜色 / 无障碍文案）。
///
/// 收成一个结构体，而不是继续给 `action` 加参数：SwiftLint 的 `function_parameter_count`
/// 是**默认开启**的规则（warning 5 / error 8），七参数版本会直接让 CI 变红。
private struct DownloadSelectionActionItem {
    let title: String
    let systemImage: String
    let detail: String
    let tint: Color
    let enabled: Bool
    let accessibilityLabel: String
}
