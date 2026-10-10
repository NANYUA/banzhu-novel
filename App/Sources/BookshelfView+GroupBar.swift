import ComposableArchitecture
import NovelCore
import SwiftUI

/// 书架分组栏（U5-4 从 `BookshelfView.swift` 原样拆出）。
///
/// ## 为什么单独一个文件
/// `BookshelfView.swift` 已逼近 SwiftLint `file_length`（warning 600），
/// 而这一块自成一个整体：只读 `ViewStore` 与三个「分组弹窗」的界面状态，
/// 与书架列表零耦合 —— 整体搬走，不复制任何代码（拆分口径见 U5-4 报告）。
///
/// ## 跨文件的可见性（拆分的唯一代价）
/// - `groupBar` 必须 `internal`：`BookshelfView.body` 在另一个文件里调用它；
/// - `groupChips` / `groupNotice` / `GroupChip` 只在本文件内互相引用，仍是 `private`；
/// - `BookshelfView` 上那三个「分组弹窗」`@State` 不能再是 `private`
///   —— 跨文件的 extension 读不到 file-private 状态（那条注释留在 `BookshelfView` 里）。
extension BookshelfView {
    /// 分组栏整体：胶囊行 + 分组操作提示条 + 与列表之间的发丝分隔线。
    func groupBar(
        _ viewStore: ViewStore<BookshelfFeature.State, BookshelfFeature.Action>
    ) -> some View {
        VStack(spacing: 0) {
            groupChips(viewStore)

            if let notice = viewStore.groupNotice {
                groupNotice(notice, viewStore: viewStore)
            }

            // 分组栏与列表之间的一条发丝分隔线（系统 `Divider()`，不自算 1px）。
            // 滚动列表时它固定不动，把「筛选」和「内容」两个区块分开。
            Divider()
        }
        .background(AppTheme.Surface.page)
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
    }
}
