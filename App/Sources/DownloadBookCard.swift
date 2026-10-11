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
/// 封面块 60×80 + 书名（`.headline`）+ 作者（`.caption`）+ 次要信息（`.caption` / `.caption2`），
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
    /// 由抬手时的 `primaryAction` 消费。
    ///
    /// ## 生命周期（🔴 这是本卡最容易改坏的一处，三个时点必须都看清）
    /// 1. **置位**：`longPressGesture` 的 `onChanged(true)` —— 按下满 0.5s 那一刻，
    ///    **严格早于抬手**；
    /// 2. **清零 ①**：`touchDownGesture` 的 `onChanged` —— **下一次触摸按下那一刻**，
    ///    严格早于该次触摸的抬手；
    /// 3. **清零 ②**：`primaryAction` 丢弃本次单点时顺手清（幂等，只是兜底）。
    ///
    /// ## 为什么必须有「按下沿」这个清零点（U13 缺陷的根因）
    /// 原先只有第 3 个清零点（抬手时由 Button 的 action 消费）—— 而**长按抬手时
    /// Button 的 action 到底会不会触发并没有保证**（长按手势是 `.simultaneousGesture`
    /// 挂上去的，手势成功识别后 Button 的 press 手势可能被取消）。
    /// 一旦它不触发，标志就永远停在 `true`：**之后每一次单击都被静默丢弃**
    /// （owner 真机反馈「长按能进选择模式、单击完全没反应」，不弹窗也不进阅读页），
    /// 而长按根本不读这个标志 ⇒ 照旧能用 —— 症状完全吻合。
    /// 把清零点补到「下一次按下」之后，标志的存活期不再依赖「抬手时谁先跑、谁触发了」。
    ///
    /// ## 为什么不用「最近一次长按时间 + 0.4s 窗口」（旧实现，owner 真机上没挡住）
    /// `LongPressGesture` 的 `onEnded` 与 `Button` 的 action **都在抬手那一刻执行**，
    /// 谁先谁后没有任何保证 —— 实测 Button 先跑，时间戳还没写进去就被判成「不是长按」；
    /// 即便顺序反过来，用户按住超过 0.4s 再抬手时那个窗口本身也已经过期。
    ///
    /// ⚠️ 这里**刻意只有一个判据**：曾经的第二个判据 `@GestureState isLongPressing`
    /// （「长按仍在进行」）已删除 —— 它在抬手那一刻的真假同样没有保证，却**能单独吞掉单击**；
    /// 只留一个生命周期明确的标志，判据更严也更可推理。
    @State private var didRecognizeLongPress = false

    var body: some View {
        // 两种模式共用同一个 Button（选择模式切换勾选 / 否则进阅读页），长按与它并行识别。
        Button(action: primaryAction) {
            cardLabel
        }
        // 强调层贴书卡自己的 12pt 圆角（`Radius.sm`），避免按下瞬间在圆角外露出方角。
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))))
        // 非选择模式长按进选择模式、选择模式再长按退出：两个模式共用同一条手势。
        .simultaneousGesture(longPressGesture)
        // 按下沿：每次**新触摸按下**时把长按标志清掉（U13 缺陷的修法，见 `touchDownGesture`）。
        // 与上面那条并列识别，互不抢事件（都是 `.simultaneousGesture`）。
        .simultaneousGesture(touchDownGesture)
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

    /// 封面 + 书名 / 作者 / 进度 / 状态（两种模式共用的内容本体）。
    ///
    /// ## 书名 / 作者：有值才渲染
    /// 取值顺序（书库优先、快照兜底、都没有就不显示）见 `BookDownloadSummary` 的说明；
    /// 这里只负责「`nil` 就整行不渲染」—— 不留空行、不编造「未知书名 / 未知作者」。
    ///
    /// ## 内容区高度
    /// 整块 `.frame(minHeight: DownloadCardMetrics.contentHeight)`，与总进度卡片、
    /// 选择操作卡片**引用同一个高度**（= 80 = 封面高）：文字列（≈74pt）与封面（80）取大 ⇒
    /// 三张卡与书架 `BookRow` 的白卡高逐值相同（80 + 内边距 12×2 = 104）。
    /// 文字列的算式与「状态与进度条并排」的来由见 `DownloadCardMetrics.contentHeight`。
    var content: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            cover

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                if let title = summary.title {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                if let author = summary.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("已下载 \(summary.finishedCount)/\(summary.tasks.count) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 进度条与状态行**并排一行**（U13）：文字列因此从 ≈82pt 压到 ≈74pt，
                // 装得进 `contentHeight`(80)。信息一条不少 —— 进度条与状态各自都还在，
                // 只是不再各占一整行（算式见 `DownloadCardMetrics.contentHeight`）。
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ProgressView(value: summary.progress)
                        // 进度已由上面那行文字给全（VoiceOver 读「已下载 12/30 章」），
                        // 进度条只是视觉强化，不再重复读一遍。
                        .accessibilityHidden(true)

                    Text(summary.status.text)
                        .font(.caption2)
                        .foregroundStyle(summary.status.color)
                        .lineLimit(1)
                        // 状态是短标签，先拿满自身宽度、剩下的才给进度条：
                        // 被进度条挤成「…」会丢掉它要传达的信息（需验证 / 失败 / 已全部下载）。
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: DownloadCardMetrics.contentHeight)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .contentShape(Rectangle())
    }

    /// 封面：书库里的**真封面**优先（`summary.coverUrl`，来自 `BookRecord.coverUrl`）；
    /// 地址为空 / 还没加载出来 / 加载失败 ⇒ 回退占位块。
    ///
    /// 尺寸与圆角沿用书架书卡那一套（`BookRow` 的 60×80 + `Radius.sm`），不另造一套观感。
    /// 高度引用 `DownloadCardMetrics.coverHeight`（= 80，与 `BookRow` 同值）：
    /// 封面写死 80 是为了让真封面（3:4）不被拉高、上下不留底色带；
    /// 卡片内容区高度另由 `contentHeight` 负责（两者当前同值，见 `content`）。
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
        .frame(width: 60, height: DownloadCardMetrics.coverHeight)
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

    /// **按下沿**：每一次新触摸的起点，把长按标志归零。
    ///
    /// ## 为什么这就是顺序无关的
    /// 一次触摸内三个时点严格有序：**按下**（本手势的 `onChanged`）→ 长按**识别**（0.5s 后，
    /// 置位）→ **抬手**（`primaryAction` 消费）。清零点排在置位点之前、置位点排在消费点之前，
    /// 全部发生在**同一次触摸内部**，不跨回调比较先后 ⇒
    /// - Button 的 action 在长按抬手时**触发**：读到 `true`，丢弃这次单点（判据 ② 不回归）；
    /// - Button 的 action **不触发**：标志也不会残留到下一次触摸（按下沿会清），
    ///   紧接着的第一次单击读到 `false`，照常进阅读页 / 切换勾选（判据 ①）。
    ///
    /// ## 为什么用「零时长长按」而不是别的
    /// 它只做一件事：在**按下那一刻**回调一次 `onChanged(true)`（与上面那条 0.5s 手势
    /// 「识别那一刻回调」同源）。不是 `DragGesture`（那会与 `List` 的滚动手势抢识别），
    /// 也不引 `@GestureState`（它在抬手时的真假没有保证，正是本次要除掉的东西）。
    /// `minimumDuration: 0` ⇒ 短点与长按都会走到这里；`false` 是抬手 / 复位，直接忽略。
    var touchDownGesture: some Gesture {
        LongPressGesture(minimumDuration: 0)
            .onChanged { isRecognized in
                guard isRecognized else { return }
                didRecognizeLongPress = false
            }
    }

    /// 单点动作：按当前模式分派（选择模式 = 切换勾选，否则 = 进阅读页）。
    ///
    /// 抬手时若本次触摸**已经被识别成长按**（`didRecognizeLongPress`），就丢弃这次单点 ——
    /// 否则「长按进选择模式」会顺手把书打开（owner 真机反馈的缺陷），
    /// 或把刚切换的勾选又翻回去。
    ///
    /// ⚠️ 判据只有这一个标志，且它**不可能**残留到下一次触摸（清零点见 `touchDownGesture`）
    /// ⇒ 单击不会被静默丢弃；标志的真假只由「本次触摸有没有被识别成长按」决定。
    func primaryAction() {
        if didRecognizeLongPress {
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
///
/// ## 🔴 书名 / 作者的取值顺序（单一真相，改之前先想清楚）
/// 1. **书库**（`BookRecord`，经 `BookLibraryMetaLoader` 带回来的 `BookLibraryMeta`）：
///    用户能看到的真值，非空即用；
/// 2. **任务快照**（`DownloadTaskSnapshot.bookTitle`）：书库里没有这本书时兜底
///    （可以下载一本没加入书架的书 ⇒ 没有 `BookRecord`）；
/// 3. **`nil`**：两处都拿不到（历史脏数据 `bookTitle == ""`）⇒ 卡上**不渲染那一行**。
///    ⛔ 不编造「未知书名 / 未知作者」—— 编出来的名字比空更误导。
///
/// 作者只有第 1 步有值（`DownloadTaskSnapshot` 里没有 author 字段），取不到即 `nil`。
/// 这条顺序让存量脏数据（`bookTitle == ""`）在**显示时自愈**：只要书还在书架里，
/// 书名与作者就照常显示，不必等重新下载。
struct BookDownloadSummary: Identifiable {
    let id: String
    /// 书名。`nil` = 没有可显示的书名（见上）。阅读页角落标签用 `title ?? ""`。
    let title: String?
    /// 作者。`nil` = 没有可显示的作者（书库没有这本书，或书库里的作者是空串）。
    let author: String?
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
/// `metas` 是 `bookPath → BookLibraryMeta`（`BookLibraryMetaLoader` 一次读库的产物）：
/// 任务快照里既没有封面也没有作者，书名还可能被历史脏数据写成空串，
/// 故由调用方**一次性**查好传进来 —— 书卡自己不去查库（`List` 滚动时逐卡查库是重活）。
/// 书名 / 作者的取值顺序见 `BookDownloadSummary`。
func bookSummaries(
    from tasks: [DownloadTaskSnapshot],
    order: [String],
    metas: [String: BookLibraryMeta] = [:]
) -> [BookDownloadSummary] {
    order.compactMap { bookPath in
        let bookTasks = tasks.filter { $0.bookPath == bookPath }
        guard let first = bookTasks.first else { return nil }
        let meta = metas[bookPath]
        return BookDownloadSummary(
            id: bookPath,
            title: firstNonEmpty(meta?.title, first.bookTitle),
            author: firstNonEmpty(meta?.author),
            coverUrl: firstNonEmpty(meta?.coverUrl),
            tasks: bookTasks
        )
    }
}

/// 按顺序取第一个**非空**值；全空（或都没值）⇒ `nil`（调用方据此不渲染那一行）。
///
/// `BookRecord` 的字段是非可选 `String`（可能为空串），而 `BookDownloadSummary` 用 `nil`
/// 表示「不显示」—— 这个函数是两者之间**唯一**的换算处（不要在别处再写一次 `?? ""`）。
private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, !value.isEmpty {
            return value
        }
    }
    return nil
}

/// 下载卡片族的共享尺度（书卡 / 总进度卡片 / 选择操作卡片）。
///
/// ## 为什么需要它
/// owner 口径：「操作卡片、总进度卡片都和书卡一样的尺寸」。三张卡片必须引用**同一个**
/// 「内容区高度」：出现第二份高度值就会各自漂移，而选择卡片与总进度卡片还要在
/// **同一个位置交替展示**，高度不一致会直接看到跳变。
///
/// ## 高度是怎么算出来的（U12：书卡补上作者行之后）
/// 卡片高 = 内容区高度 + 内边距 `Spacing.sm`(12) × 2，列表里再套一层
/// `.downloadQueueCard()` 的 8×2 ⇒ 可见卡高再加 16pt。
/// 内容区高度取三张卡里最高的那个（书卡文字列），封面 60×80 只是书卡里的一个内容块。
///
/// ## 为什么放这里而不是 `DesignTokens`
/// `DesignTokens` 是**通用**尺度刻度（间距 / 圆角），不含任何业务尺寸；本枚举是
/// **下载卡片族专有**的尺寸，与 `ReaderView+Chrome.swift` 的 `ReaderChromeMetrics` 同一先例
/// （通用值进令牌、模块专有值收在模块自己的 metrics 里）。而且 `DesignTokens.swift` 只声明了
/// `Spacing` / `Radius` 两段，为它新开一段尺寸段会把通用令牌表变成业务尺寸的堆场。
enum DownloadCardMetrics {
    /// 书卡**封面块**高度（宽 60）—— 与书架 `BookRow` 的封面同尺寸，`Radius.sm` 圆角。
    ///
    /// ⚠️ 它只决定封面块本身，**不是**卡片内容区高度的真相源（那是 `contentHeight`）；
    /// 两者当前**同值 80**（U13 起封面重新成为高度来源）：真封面是 3:4 = 60×80，
    /// 封面若被拉高就会在上下各留一条 `Surface.inset` 底色带，所以封面高度写死在这里。
    static let coverHeight: CGFloat = 80

    /// 卡片**内容区最小高度**（书卡 / 总进度卡片 / 选择操作卡片三处共用）。
    ///
    /// 加上卡片内边距 `Spacing.sm`(12) × 2 后，三张白卡的高度都是 **104pt**
    /// （列表里再套 `.downloadQueueCard()` 的 8×2 ⇒ 可见卡高 120pt）——
    /// **与书架书卡 `BookRow` 逐值相同**（封面 80 + `.padding(Spacing.sm)` 12×2 = 104）。
    ///
    /// ## 为什么是 80（算式）
    /// 取书卡内容里**最高**的那一块：
    /// - **封面** `.frame(width: 60, height: coverHeight)` = **80**；
    /// - **文字列** = 书名 `.headline`(17pt，行高 ≈20.3) + `Spacing.xxs`(4)
    ///   + 作者 `.caption`(12pt，≈14.3) + 4 + 「已下载 N/M 章」`.caption`(≈14.3) + 4
    ///   + 「进度条 ‖ 状态」并排一行 = max(进度条 ≈4, 状态 `.caption2`(11pt，≈13.1)) ≈ 13.1
    ///   ⇒ **≈74.0pt**。
    /// 两者取大 = **80** ⇒ 内容区 80 + 12×2 = 104，与书架卡一致。
    ///
    /// ⚠️ 原先这里写 88：那时「状态」独占一行（文字列 ≈82 > 封面 80），
    /// 书卡白卡高因此是 112 而书架卡是 104 —— owner 反馈的「下载界面卡片大小和书架的卡片
    /// 大小不一致」就是这 8pt。压回 80 的前提是把文字列压进 80：U13 把**状态行与进度条并排**
    /// （信息一条不少：书名 / 作者 / 已下载 N/M 章 / 进度条 / 状态**全都还在**）。
    ///
    /// ⚠️ 同高的判据是「三处内容都 `.frame(minHeight: contentHeight)`」——
    /// 书卡文字列一旦长过它（超大 Dynamic Type 等）就会重新把书卡顶高，这是刻意的
    /// （宁可让内容不被裁掉，也不钉死高度把字切掉）。
    static let contentHeight: CGFloat = 80

    /// 总进度卡片右列（百分比 + 「暂停全部」）的固定宽度。
    ///
    /// 固定宽度是为了让「进度条右端左移缩短、给右侧按钮让位」这条口径可复现：
    /// 左列 `maxWidth: .infinity` 吃掉剩余宽度，进度条自然缩短，且不随百分比文字长短抖动。
    /// 取 106 的依据：`.subheadline`(15pt) 下「暂停全部」= 图标约 13 + 标签间距约 6
    /// + 4 个中文字约 60 ≈ 79pt，再加 `.borderedProminent` 自身左右内边距约 12×2 ⇒ 约 103pt，
    /// 106 是覆盖它的整数。
    static let progressColumnWidth: CGFloat = 106

    /// 选择操作卡片里图标块的边长（38×38）。
    static let actionIconSize: CGFloat = 38
}

// MARK: - 卡片装饰（与书架同源）

/// 卡片装饰**刻意不是 `private`**：书卡在本文件、提示条在 `DownloadQueueView.swift`、
/// 总进度卡片在 `DownloadSummaryCard.swift` —— 三处必须共用同一套卡面
/// （`Surface.card` + `Radius.sm`），否则「同一页两种卡片」。
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
