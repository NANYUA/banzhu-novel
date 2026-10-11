import ComposableArchitecture
import NovelCore
import SwiftUI

/// 书架分组栏（U5-4 从 `BookshelfView.swift` 原样拆出）。
///
/// ## 为什么单独一个文件
/// 这一块自成一个整体：只读 `ViewStore` 与三个「分组弹窗」的界面状态，
/// 与书架列表零耦合 —— 整体搬走，不复制任何代码（拆分口径见 U5-4 报告）；
/// 拆出后 `BookshelfView.swift` 与本文件都远离 SwiftLint `file_length` 门槛。
///
/// ⚠️ 本文件是**两个「完成」出口**的共同落点（都钉在分组栏最右边、共用同一个胶囊 `selectionDoneChip`）：
/// 1. **书架编辑态**（「全部」及任何非本地分组）—— 状态是 `BookshelfFeature.State.isEditing`，
///    本文件本来就读得到它；owner 第十轮第 3 条把出口从**导航栏左上角**搬到了这里；
/// 2. **下载选择模式**（本地分组）—— 状态住在 `DownloadFeature`，故 `groupBar` 还收一个
///    `StoreOf<DownloadFeature>`（U13 起）；它只读那一个 Bool，与书架列表仍然零耦合。
/// ⇒ 两个判据**互斥、永不共存**（见 `groupBar` 里的说明）。
///
/// ## 跨文件的可见性（拆分的唯一代价）
/// - `groupBar` 必须 `internal`：`BookshelfView.body` 在另一个文件里调用它；
/// - `groupChips` / `groupNotice` / `GroupChip` 只在本文件内互相引用，仍是 `private`；
/// - `BookshelfView` 上那三个「分组弹窗」`@State` 不能再是 `private`
///   —— 跨文件的 extension 读不到 file-private 状态（那条注释留在 `BookshelfView` 里）。
extension BookshelfView {
    /// 分组栏整体：胶囊行（+ 两个「完成」出口）+ 分组操作提示条 + 与列表之间的发丝分隔线。
    ///
    /// ## 两个「完成」出口（互斥、永不共存）
    /// | 出口 | 判据 | 状态住在哪 |
    /// |---|---|---|
    /// | 书架编辑态 | `viewStore.isEditing && !viewStore.showsLocalGroup` | `BookshelfFeature`（本文件本来就读得到） |
    /// | 下载选择模式 | `downloadViewStore.state`（= `DownloadFeature.isSelecting`） | `DownloadFeature` ⇒ 需透传 store |
    ///
    /// ## 为什么这里要收一个 `DownloadFeature` 的 store（U13）
    /// 「完成」（退出下载选择模式）**原先是下载页常驻上栏里的一行文字按钮**，owner 要求把它
    /// 挪到分组栏最右边、并改用分组标签的样式。而选择模式的状态住在 `DownloadFeature`
    /// （`State.isSelecting`），分组栏本身属于 `BookshelfFeature` ⇒ 由本视图把 `downloadStore`
    /// 透传进来，在**同一个文件内**就地观察它（`WithViewStore` 的派生 Bool，照 `RootView` 的写法）。
    ///
    /// 这样做的取舍（为什么不让 `BookshelfView.body` 用 `HStack` 把「完成」拼在右边）：
    /// 「只在选择模式渲染」这条判据与它控制的布局同处一地；`GroupChip` 是本文件的 `private`，
    /// 留在本文件就能直接复用（不必放宽可见性、更不必复制一份胶囊样式）；`BookshelfView.body`
    /// 只多一个实参，不必在那个已经很大的函数里再嵌一层 `WithViewStore`。
    ///
    /// ⚠️ 「完成」**不放进 `groupChips` 的那个横向 `ScrollView`** —— 它在 `HStack` 里与
    /// `ScrollView` **并列**，所以钉在右边缘不动、不随分组标签横向滚动（owner 裁决）。
    func groupBar(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>,
        downloadStore: StoreOf<DownloadFeature>
    ) -> some View {
        WithViewStore(downloadStore, observe: \.isSelecting) { downloadViewStore in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    groupChips(viewStore)

                    // ① **书架编辑态**的「完成」出口（owner 第十轮第 3 条）：原先是导航栏**左上角**
                    // 的一个文字按钮，现搬到分组栏最右边、用同一套胶囊样式。语义逐字不变。
                    //
                    // ⚠️ `!showsLocalGroup` **不能省**（U9-8 的回归护栏）：`.groupSelected` /
                    // `.localGroupSelected` 都**不重置** `isEditing`（`BookshelfFeature.swift:147-162`），
                    // 而本地分组装的是下载任务、不是书目 ⇒ 本地态归下面那条分支管。
                    // ⇒ 省掉它，本地分组会**同时**长出两个「完成」。
                    if viewStore.isEditing, !viewStore.showsLocalGroup {
                        selectionDoneChip {
                            viewStore.send(.editModeChanged(false))
                        }
                    }

                    // ② **下载选择模式**（本地分组）的「完成」出口（round-9）。与 ① 互斥、永不共存。
                    if downloadViewStore.state {
                        selectionDoneChip {
                            downloadStore.send(.selectionModeChanged(false))
                        }
                    }
                }

                if let notice = viewStore.groupNotice {
                    groupNotice(notice, viewStore: viewStore)
                }

                // 分组栏与列表之间的一条发丝分隔线（系统 `Divider()`，不自算 1px）。
                // 滚动列表时它固定不动，把「筛选」和「内容」两个区块分开。
                Divider()
            }
            .background(AppTheme.Surface.page)
        }
    }

    /// **两个「完成」出口共用的胶囊**：钉在分组栏最右边的「完成」；**不满足渲染条件时不渲染（零高度）**。
    ///
    /// - 书架编辑态：语义 = `BookshelfFeature` 的 `.editModeChanged(false)`
    ///   （与原先导航栏左上角那个 `Button("完成")` **逐字相同**）；
    /// - 下载选择模式：语义 = `DownloadFeature` 的 `.selectionModeChanged(false)`
    ///   （与长按退出**逐字相同**）。
    ///
    /// 两者**只是语义不同的两个调用点**，样式与位置共用这一处 ⇒ 不会出现「两个完成长得不一样」。
    ///
    /// ## 样式：复用 `GroupChip` 的**未选中**态（白卡面 + 主色文字）
    /// owner 口径是「移动到分组栏最右边，样式为分组栏的样式」⇒ 直接用分组标签那一个组件，
    /// 不复制一份胶囊样式（内边距 / 字号 / 按下反馈 / 44pt 命中区都随之逐值相同）。
    ///
    /// ⚠️ **刻意不用选中态**（`isSelected: true` 是 accent 填充）—— 那是「当前选中的分组」的
    /// 视觉语言，用在「完成」上会让人读成「某个分组被选中了」，属语义误导。未选中态与分组标签
    /// 同一套观感，按惯例它就是可点的。⇒ 若日后要更醒目，改 `isSelected: true` 即可（一行），
    /// **但那要先由 owner 拍板**，不要在这里「顺手改醒目」。
    ///
    /// ## 命中区（≥ 44×44 的算式）
    /// 宽 = 「完成」二字在 `.subheadline`(15pt) 下约 30pt + `padding(.horizontal, Spacing.md)` 16×2 = **62pt**；
    /// 高 = `GroupChip` 自身的 `.frame(minHeight: 44)` = **44pt** ⇒ **62×44 ≥ 44×44** ✓
    /// （胶囊自带的 `Spacing.xs` 垂直内边距只影响绘制高度，命中区由 `minHeight` 兜住）。
    private func selectionDoneChip(_ action: @escaping () -> Void) -> some View {
        GroupChip(title: "完成", isSelected: false, action: action)
            // 与页面右边缘留出标准页边距（`Spacing.md`），和分组标签行左侧的内缩同源。
            .padding(.trailing, DesignTokens.Spacing.md)
    }

    private func groupChips(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                // 「全部」= 隐含视图（不占记录）。判据用 `isAllSelected` 而不是
                // `selectedGroupID == nil`：选中「本地」时后者同样是 `nil`，
                // 只看它会让「全部」与「本地」两个胶囊同时高亮（见 `State.isAllSelected`）。
                GroupChip(
                    title: "全部",
                    isSelected: viewStore.isAllSelected
                ) {
                    viewStore.send(.groupSelected(nil))
                }

                // 「本地」= **固定**分组：装的是下载队列，不是书，所以它不在 SwiftData 里，
                // 也就没有 `contextMenu` —— 既不能改名也不能删除（`BookGroup` 是用户数据）。
                // 位置固定在「全部」之后、用户分组之前：前半段是系统固定项，后半段才是用户分组，
                // 末尾的「+」紧挨用户分组，不会被误读成「本地」的操作。
                GroupChip(
                    title: "本地",
                    isSelected: viewStore.showsLocalGroup
                ) {
                    viewStore.send(.localGroupSelected)
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("新建分组")
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
    }

    private func groupNotice(
        _ notice: String,
        viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(AppTheme.statusAttention)
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
            // §9 按下反馈：`.plain` 按下零反馈；强调层按 12pt 内缩贴图标自身的圆，
            // 不铺成 44pt 大圆盘（命中区仍由 label 的 44×44 + `.contentShape` 提供）。
            .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Circle().inset(by: DesignTokens.Spacing.sm))))
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }
}

// MARK: - 分组胶囊

/// 分组胶囊：「全部」/「本地」/ 用户分组共用同一个组件（U5-4 起「本地」也走它，不另造样式）。
private struct GroupChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.xs)
                // §9 触控目标：胶囊本身做到 44pt —— 强调层贴的就是它，所以不会出现「按下变胖」。
                .frame(minHeight: 44)
                // 未选中 = 白卡面 + 主色文字（U1-1 的「卡面 = 白」同样适用于分组栏里的贴片）；
                // 选中 = 品牌强调色填充。
                .background(
                    Capsule().fill(
                        isSelected ? AppTheme.accent : AppTheme.Surface.card
                    )
                )
                // ⚠️ 这里的 `Color.white` 是 owner **已裁定「保持现状」**的一项：深色下
                // 强调色填充配白字是 3.65:1，而任何单一深色值都无法同时满足「小字压在卡片上
                // ≥ 4.5」与「填充配白字 ≥ 4.5」（论证见 `AppTheme.accent` 文档）。
                // **不要**改这一处颜色，也不要为此新增硬编码色。
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        // 强调层贴胶囊轮廓，避免按下瞬间两端露出方角（U0-4）。
        .buttonStyle(PressableCardButtonStyle(pressedScale: 0.96, shape: AnyShape(Capsule())))
        // 选中语义交给 Button 的 `.isSelected` trait（照抄 `BookshelfView` 编辑态行的形式）：
        // 「全部」/「本地」/ 用户分组共用这一处，VoiceOver 才读得出「当前选中」。
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
