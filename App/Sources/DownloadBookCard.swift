import NovelCore
import SwiftUI

/// 下载队列里的**书卡**：一本书一张卡，下载进度写在卡面上。
///
/// ## 为什么不再有逐章行
/// owner 口径：本地页要显示成书籍卡片，**已下载的章节不在队列里逐条列**
/// （要去书籍阅读界面的目录里看）。于是原先「书名 header + N 条章节任务行」
/// 收成一张卡，进度与状态**聚合到书一级**（`BookDownloadSummary`）。
///
/// ## 视觉语言与书架同源
/// 封面块 60×80 + 书名（`.headline`）+ 次要信息（`.caption` / `.caption2`），
/// 卡面 `AppTheme.Surface.card` + `Radius.sm`，按下反馈复用 `PressableCardButtonStyle`
/// —— 与 `BookshelfView` 的 `BookRow` 是同一套观感。
///
/// ⚠️ 封面优先走**真封面**（`BookDownloadSummary.coverUrl`，来自书库的 `BookRecord.coverUrl`）；
/// 取不到 / 加载失败 / 地址为空时回退到占位块（`Surface.inset` + `book` 符号，
/// 与 `BookRow.placeholder` 同观感）—— 占位块是兜底，不是废码。
///
/// ## 单点语义（owner 需求）
/// 非选择模式下**单点 = 直接进阅读页**（落点 = 上次看过的页面，从未看过 ⇒ 第一章第一页）；
/// 选择模式下**单点 = 切换勾选**（与书架编辑态一致）。两种模式都保留长按：
/// 非选择模式长按进选择模式、选择模式再长按退出。
///
/// ## 单点区域 = 整张卡（U11）
/// 右上角「更多」菜单删除后，卡上不再有需要独立命中的兄弟控件 ⇒ 不必再把
/// 「封面 + 文字」单独包一层 Button：整张卡就是一个按钮，命中区与按下强调层
/// 因此**铺满整卡**（原先「右上角那块不是单点区」的例外随之消失）。
struct DownloadBookCard: View {
    let summary: BookDownloadSummary
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    /// 非选择模式下的单点动作：直接进阅读页。
    let onOpenBook: () -> Void
    let onLongPress: () -> Void

    /// 长按**已识别**标志：在长按被识别的那一刻（按下满 0.5s，**抬手之前**）置位，
    /// 由抬手时 Button 的 action **消费**（见 `primaryAction`）。
    ///
    /// ⚠️ 为什么不用「最近一次长按时间 + 0.4s 窗口」（旧实现，owner 真机上没挡住）：
    /// `LongPressGesture` 的 `onEnded` 与 `Button` 的 action **都在抬手那一刻执行**，
    /// 谁先谁后没有任何保证 —— 实测 Button 先跑，时间戳还没写进去就被判成「不是长按」；
    /// 即便顺序反过来，用户按住超过 0.4s 再抬手时那个窗口本身也已经过期。
    /// 改成「识别即置位、抬手即消费」后，判据只依赖**本次触摸有没有被识别成长按**，
    /// 与两个回调的先后顺序、与用户按住多久都无关。
    @State private var didRecognizeLongPress = false

    /// 长按**进行中**（识别到长按之后、抬手之前）。
    ///
    /// 与 `didRecognizeLongPress` 是**两个独立判据**，抬手时任一为真就丢弃这次单点 ——
    /// 二者覆盖的时序不同，合起来才不依赖「`onChanged` / `onEnded` / Button action 谁先跑」：
    /// - `@GestureState` 由 SwiftUI 在长按**识别时**置位、手势结束时**自动复位**
    ///   （不靠我们清标志 ⇒ 不存在「标志残留、下一次短点被吞」的风险）；
    /// - 它取的是手势自己的值 ⇒ 短点全程为 `false`，**不会误伤短点**。
    @GestureState private var isLongPressing = false

    var body: some View {
        // 两种模式共用同一个 Button（选择模式切换勾选 / 否则进阅读页），长按与它并行识别。
        Button(action: primaryAction) {
            cardLabel
        }
        // 强调层贴书卡自己的 12pt 圆角（`Radius.sm`），避免按下瞬间在圆角外露出方角。
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))))
        // 非选择模式长按进选择模式、选择模式再长按退出：两个模式共用同一条手势。
        .simultaneousGesture(longPressGesture)
        // 装饰性勾选图的语义交给 Button 的 `.isSelected` trait，避免 VoiceOver 读两遍。
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension DownloadBookCard {
    /// 卡面：勾选框（选择模式）+ 封面 + 书名 / 进度 / 状态。
    ///
    /// ## 可点区域与内边距
    /// 整张卡由 `body` 那一个 Button 包住（U11：右上角「更多」菜单删除后，
    /// 卡上不再有需要独立命中的兄弟控件）⇒ 卡面这里只负责「内容怎么排」，
    /// 不再自己包 Button。
    ///
    /// 卡片内边距由各块**各自持有**（而不是 HStack 统一 `.padding`），
    /// 这样命中区与强调层能一直铺到卡片边缘，不在四周留一圈点不动的死区；
    /// 各块之间的间隔与原实现逐值相同。
    var cardLabel: some View {
        HStack(spacing: 0) {
            if isSelecting {
                selectionMark
            }

            content
        }
        .contentShape(Rectangle())
        .background(
            AppTheme.Surface.card,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
    }

    /// 选择模式的勾选框（装饰性图形：选中语义交给 Button 的 `.isSelected` trait）。
    var selectionMark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AppTheme.accent : Color.secondary)
            .accessibilityHidden(true)
            .padding(.leading, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
    }

    /// 封面 + 书名 / 进度 / 状态（两种模式共用的内容本体）。
    var content: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            cover

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("已下载 \(summary.finishedCount)/\(summary.tasks.count) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProgressView(value: summary.progress)
                    // 进度已由上面那行文字给全（VoiceOver 读「已下载 12/30 章」），
                    // 进度条只是视觉强化，不再重复读一遍。
                    .accessibilityHidden(true)

                Text(summary.status.text)
                    .font(.caption2)
                    .foregroundStyle(summary.status.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .contentShape(Rectangle())
    }

    /// 封面：书库里的**真封面**优先（`summary.coverUrl`，来自 `BookRecord.coverUrl`）；
    /// 地址为空 / 还没加载出来 / 加载失败 ⇒ 回退占位块。
    ///
    /// 尺寸与圆角沿用书架书卡那一套（`BookRow` 的 60×80 + `Radius.sm`），不另造一套观感。
    var cover: some View {
        AsyncImage(url: coverURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
            case .empty, .failure:
                coverPlaceholder
            @unknown default:
                coverPlaceholder
            }
        }
        .frame(width: 60, height: 80)
        .background(AppTheme.Surface.inset)
        .cornerRadius(DesignTokens.Radius.sm)
    }

    /// 封面地址。`coverUrl` 缺失或为空串 ⇒ `nil`：`AsyncImage` 会一直停在 `.empty`，
    /// 于是走占位块（不拿空串去建 URL）。
    var coverURL: URL? {
        guard let raw = summary.coverUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// 占位块：与 `BookRow.placeholder` 同观感。**是兜底，不是废码**
    /// （没加入书架的书根本没有 `BookRecord`，也就查不到封面）。
    var coverPlaceholder: some View {
        Rectangle()
            .fill(AppTheme.Surface.inset)
            .overlay {
                Image(systemName: "book")
                    .font(.title3)
                    .foregroundStyle(.quaternary)
            }
    }

    /// 长按：**按下阶段**（长按被识别那一刻）置位标志，抬手时由 `primaryAction` 消费。
    ///
    /// 两种模式共用同一条手势：非选择模式长按进选择模式、选择模式再长按退出
    /// （都由调用方在 `onLongPress` 里切换 `selectionModeChanged`）。
    var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .updating($isLongPressing) { isRecognized, state, _ in
                // `state = value`（而不是恒 `true`）：按下但还没到 0.5s 时必须是 `false`，
                // 否则短点抬手时也会被判成长按。
                state = isRecognized
            }
            .onChanged { isRecognized in
                // ⚠️ 关键在时机：`onChanged` 在**按下阶段**回调（长按刚被识别、抬手之前），
                // 而 `onEnded` 与 Button 的 action 都在抬手时执行、顺序不保证
                // ⇒ 标志只能在这里置位（旧实现写在 `onEnded` 里，真机上没挡住）。
                // 只在 `true` 时置位：`false` 是抬手 / 复位，不能反过来把标志清掉。
                guard isRecognized else { return }
                didRecognizeLongPress = true
            }
            .onEnded { _ in
                onLongPress()
            }
    }

    /// 单点动作：按当前模式分派（选择模式 = 切换勾选，否则 = 进阅读页）。
    ///
    /// 抬手时若本次触摸**已经被识别成长按**（`didRecognizeLongPress`）或长按**仍在进行**
    /// （`isLongPressing`），就丢弃这次单点 —— 否则「长按进选择模式」会顺手把书打开
    /// （owner 真机反馈的缺陷），或把刚切换的勾选又翻回去。
    func primaryAction() {
        if didRecognizeLongPress || isLongPressing {
            didRecognizeLongPress = false
            return
        }
        if isSelecting {
            onToggleSelection()
        } else {
            onOpenBook()
        }
    }
}

/// 一本书在下载队列里的聚合（书卡只读它 —— 逐章任务行已不再渲染）。
struct BookDownloadSummary: Identifiable {
    let id: String
    let title: String
    /// 封面地址（来自书库 `BookRecord.coverUrl`）；库里没有这本书、或地址为空时是 `nil`
    /// ⇒ 书卡回退占位块。`DownloadTaskSnapshot` 里没有这个字段，由 `bookSummaries` 并进来。
    let coverUrl: String?
    let tasks: [DownloadTaskSnapshot]

    var finishedCount: Int {
        tasks.filter(\.state.isFinished).count
    }

    /// 已完成 / 总数（书卡按「队列里有这本书」建立，`tasks` 不会为空）。
    var progress: Double {
        tasks.isEmpty ? 0 : Double(finishedCount) / Double(tasks.count)
    }

    private var failedCount: Int {
        tasks.filter { $0.state == .failed }.count
    }

    private var blockedCount: Int {
        tasks.filter(\.blockedByGuard).count
    }

    private var pausedCount: Int {
        tasks.filter { $0.state == .paused }.count
    }

    private func hasTask(in state: DownloadState) -> Bool {
        tasks.contains { $0.state == state }
    }

    /// 状态行：把原先逐章行上的状态**聚合到书一级**。
    ///
    /// 优先级：需要验证 > 失败 > 下载中 > 等待 > 已暂停 > 全部完成。
    /// 阻塞与失败必须排在「下载中」之前 —— 它们要用户处理，不能被一个正在跑的分支盖掉。
    var status: BookDownloadStatus {
        if blockedCount > 0 {
            return .blocked(blockedCount)
        }
        if failedCount > 0 {
            return .failed(failedCount)
        }
        if hasTask(in: .downloading) {
            return .downloading
        }
        if hasTask(in: .queued) {
            return .queued
        }
        if pausedCount > 0 {
            return .paused
        }
        return .finished
    }
}

/// 书卡状态行的取值（书一级聚合，替代原先逐章行的状态文字）。
enum BookDownloadStatus {
    case blocked(Int)
    case failed(Int)
    case downloading
    case queued
    case paused
    case finished

    var text: String {
        switch self {
        case let .blocked(count):
            "\(count) 章需要验证"
        case let .failed(count):
            "\(count) 章下载失败"
        case .downloading:
            "正在下载"
        case .queued:
            "等待下载"
        case .paused:
            "已暂停"
        case .finished:
            "已全部下载"
        }
    }

    /// 状态色统一：进行中 = 强调色，已完成 = 系统绿，需注意 = 橙，失败 = 红。
    var color: Color {
        switch self {
        case .blocked:
            AppTheme.statusAttention
        case .failed:
            AppTheme.statusDanger
        case .downloading:
            AppTheme.accent
        case .queued, .paused:
            .secondary
        case .finished:
            AppTheme.statusAdded
        }
    }
}

/// 把任务按书归拢成书卡数据。
///
/// 顺序由调用方传入（`DownloadFeature.State.bookPaths`）—— 「队列里有哪些书、按什么顺序」
/// 只有那一处定义，「全选」判据与书卡分组共用它，视图不自己再算一遍。
///
/// `covers` 是 `bookPath → coverUrl`（`BookCoverLoader` 一次读库的产物）：
/// 任务快照里没有封面地址，封面真值在 `BookRecord` 上，故由调用方**一次性**查好传进来 ——
/// 书卡自己不去查库（`List` 滚动时逐卡查库是重活）。
func bookSummaries(
    from tasks: [DownloadTaskSnapshot],
    order: [String],
    covers: [String: String] = [:]
) -> [BookDownloadSummary] {
    order.compactMap { bookPath in
        let bookTasks = tasks.filter { $0.bookPath == bookPath }
        guard let first = bookTasks.first else { return nil }
        return BookDownloadSummary(
            id: bookPath,
            title: first.bookTitle,
            coverUrl: covers[bookPath],
            tasks: bookTasks
        )
    }
}

/// 选择模式的批量操作栏（**本地页自带**，不复用书架那套批量工具栏）。
///
/// ## 为什么必须自带一条
/// 书架那套批量工具栏（全选 / 整本下载 / 移入分组 / 删除）在 `BookshelfView.toolbarContent`
/// 里被 `!showsLocalGroup` 明确屏蔽 —— 那里的注释写着「本地分组装的是下载任务、不是书目，
/// 这些批量操作在语义上根本不成立」。所以本地页的选择模式自带一条，操作是**下载语义**的四项：
/// 全选 / 暂停下载 / 删除下载 / 重试失败。
///
/// ## 位置与材质
/// 放在分组栏下方、列表上方（书架把批量操作放在顶部工具栏，位置习惯一致），
/// 用 `.regularMaterial` 与列表分层（同 `ChapterDownloadPicker.confirmBar` 的手法）。
struct DownloadSelectionBar: View {
    let selectedCount: Int
    let isAllSelected: Bool
    let canPause: Bool
    let canRetryFailed: Bool
    let onToggleSelectAll: () -> Void
    let onPause: () -> Void
    let onDelete: () -> Void
    let onRetryFailed: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                headerRow
                actionRow
            }
            .padding(.vertical, DesignTokens.Spacing.xs)

            Divider()
        }
        .background(.regularMaterial)
    }
}

private extension DownloadSelectionBar {
    /// 标题行：「已选 N 本」+ 退出选择模式的「完成」（与书架编辑态的「完成」同名同义）。
    var headerRow: some View {
        HStack {
            Text(selectedCount == 0 ? "选择要操作的书" : "已选 \(selectedCount) 本")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onDone) {
                Text("完成")
                    .font(.body.weight(.semibold))
                    // HIG §9：`.frame` 落在 label 上才真的撑开命中区。
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            action(
                isAllSelected ? "取消全选" : "全选",
                isAllSelected ? "checkmark.circle.fill" : "checkmark.circle",
                tint: AppTheme.accent,
                enabled: true,
                perform: onToggleSelectAll
            )
            action(
                "暂停下载",
                "pause.circle",
                tint: AppTheme.accent,
                enabled: canPause,
                perform: onPause
            )
            action(
                "删除下载",
                "trash",
                tint: AppTheme.statusDanger,
                enabled: selectedCount > 0,
                perform: onDelete
            )
            action(
                "重试失败",
                "arrow.clockwise",
                tint: AppTheme.accent,
                enabled: canRetryFailed,
                perform: onRetryFailed
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
    }

    /// 一个批量操作：图标在上、文字在下（字号走 Dynamic Type，不写死高度）。
    func action(
        _ title: String,
        _ systemImage: String,
        tint: Color,
        enabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            // 自定义 ButtonStyle 不吃 `.tint`，颜色在这里显式给；
            // 不可用时换次级色（自定义 ButtonStyle 不会自己变灰，不显式给就成了「看着能点却没反应」）。
            .foregroundStyle(enabled ? tint : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardButtonStyle(
            pressedScale: 0.96,
            shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        ))
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

// MARK: - 卡片装饰（与书架同源）

/// 卡片装饰**刻意不是 `private`**：书卡在本文件、提示条与汇总卡在 `DownloadQueueView.swift`，
/// 两处必须共用同一套卡面（`Surface.card` + `Radius.sm`），否则「同一页两种卡片」。
extension View {
    /// 不成卡的行（系统控件 / 提示条）：清行底 + 隐藏分隔线 + 书架同款左右 16pt 页边距。
    func downloadQueueRow(
        top: CGFloat = DesignTokens.Spacing.xs,
        bottom: CGFloat = DesignTokens.Spacing.xs
    ) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(
                .init(
                    top: top,
                    leading: DesignTokens.Spacing.md,
                    bottom: bottom,
                    trailing: DesignTokens.Spacing.md
                )
            )
    }

    /// 卡面（`Surface.card` + `Radius.sm`）：书卡、提示条、汇总卡共用。
    ///
    /// 原先还带 `topRounded` / `bottomRounded`（用来把同一 `Section` 内相邻的**章节行**
    /// 拼成一张卡）；逐章行删掉后没有消费者，那两个参数与
    /// `downloadQueueSectionHeaderCard()` 一并删除。
    func downloadQueueCard() -> some View {
        padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                AppTheme.Surface.card,
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            )
            .downloadQueueRow(top: 0, bottom: DesignTokens.Spacing.xs)
    }
}
