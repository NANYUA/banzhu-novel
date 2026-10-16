import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

extension ExploreView {
    /// 完整分组栏（三行筛选 + 底部分隔线）。
    ///
    /// owner 口径「书籍卡片上滑时先整体上移盖住分组，然后书籍卡片再从三个已选值下方划走」：
    /// 完整栏放进滚动内容里、跟随书目列表一起滚出可视区，不再原位收缩；
    /// 滚出后由 `compactBarOverlay(_:)` 挂在列表顶部接管。
    func groupBarHeader(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        let selected = exploreSelectedFilterItems(from: viewStore.selectedCategory)
        return VStack(spacing: 0) {
            ExploreGroupBar(
                categories: viewStore.categories,
                selected: selected,
                page: viewStore.page,
                onJump: { page in
                    viewStore.send(.jumpToPage(page))
                },
                onSelect: { category in
                    viewStore.send(.categorySelected(category))
                }
            )
            Divider()
        }
        .background(AppTheme.Surface.page)
    }

    /// 吸顶收缩栏「三个已选值 + 跳页按钮」。调用方以 `.overlay(alignment: .top)` 挂在列表上：
    /// 不占布局空间，出现 / 消失不会引起列表跳动；完整栏滚出的后半程淡入 + 从导航栏下缘
    /// 下滑到位，书目卡片从它下方划过。点任意选中胶囊把列表滚回顶部重新展开完整栏。
    func compactBarOverlay(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        let selected = exploreSelectedFilterItems(from: viewStore.selectedCategory)
        return VStack(spacing: 0) {
            ExploreCompactBar(
                selected: selected,
                page: viewStore.page,
                onJump: { page in
                    viewStore.send(.jumpToPage(page))
                },
                onExpand: {
                    scrollToTopToken += 1
                }
            )
            Divider()
        }
        .background(AppTheme.Surface.page)
    }
}

/// 从选中分类的 `value`（"状态|排序|分类" 三段拼接）解析出的三个维度当前选中项。
/// 完整分组栏与吸顶收缩栏共用同一份解析结果，保证两处显示一致。
private struct ExploreSelectedFilterItems {
    let status: ExploreCategory
    let sort: ExploreCategory
    let genre: ExploreCategory

    func item(for group: ExploreCategoryGroup) -> ExploreCategory {
        switch group {
        case .status: status
        case .sort: sort
        case .genre: genre
        case .legacy: ExploreCategoryCatalog.defaultCategory
        }
    }
}

/// 把 `selectedCategory.value` 按 "状态|排序|分类" 拆成三段，分别映射回三个维度目录里的选项；
/// 没有选中分类或 value 不是三段时，回退到各维度的默认项（第 0 个）。
private func exploreSelectedFilterItems(
    from selectedCategory: ExploreCategory?
) -> ExploreSelectedFilterItems {
    let segments = selectedCategory?.value?.split(separator: "|").map(String.init)
    guard let segments, segments.count == 3 else {
        return ExploreSelectedFilterItems(
            status: ExploreCategoryCatalog.statuses[0],
            sort: ExploreCategoryCatalog.sorts[0],
            genre: ExploreCategoryCatalog.genres[0]
        )
    }
    func match(_ options: [ExploreCategory], _ selectedValue: String, defaultIndex: Int) -> ExploreCategory {
        options.first(where: { $0.value == selectedValue }) ?? options[defaultIndex]
    }
    return ExploreSelectedFilterItems(
        status: match(ExploreCategoryCatalog.statuses, segments[0], defaultIndex: 0),
        sort: match(ExploreCategoryCatalog.sorts, segments[1], defaultIndex: 1),
        genre: match(ExploreCategoryCatalog.genres, segments[2], defaultIndex: 2)
    )
}

/// 滚动内容里的完整分组栏：三维筛选行各占一行，每组首行固定 3 个胶囊，
/// 行尾右对齐「展开 / 收起」（「状态」行行尾是跳页按钮）；展开后其余选项折到下一行。
private struct ExploreGroupBar: View {
    let categories: [ExploreCategory]
    let selected: ExploreSelectedFilterItems
    let page: Int
    let onJump: (Int) -> Void
    let onSelect: (ExploreCategory) -> Void

    private var visibleGroups: [ExploreCategoryGroup] {
        ExploreCategoryGroup.allCases.filter { group in
            group != .legacy && categories.contains(where: { $0.group == group })
        }
    }

    /// 点某个胶囊：该维度换成所点项、其余维度保持不变，合成一个新的选中分类上报。
    private func select(_ item: ExploreCategory) {
        let status = item.group == .status ? item : selected.status
        let sort = item.group == .sort ? item : selected.sort
        let genre = item.group == .genre ? item : selected.genre
        onSelect(ExploreCategoryCatalog.category(status: status, sort: sort, genre: genre))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            ForEach(visibleGroups, id: \.self) { group in
                ExploreCategoryFilterRow(
                    title: group.title,
                    items: categories.filter { $0.group == group },
                    selectedItem: selected.item(for: group),
                    page: group == .status ? page : nil,
                    onJump: group == .status ? onJump : nil,
                    onSelect: select
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

/// 吸顶收缩栏的单行内容：「3 个选中值胶囊 + 跳页按钮」。
/// 胶囊点击整颗滚回顶部重新展开完整栏（不切换选择）；用选中态配色
/// （accent 底 + 反色文字），沿用旧收缩栏的样式。
private struct ExploreCompactBar: View {
    let selected: ExploreSelectedFilterItems
    let page: Int
    let onJump: (Int) -> Void
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            compactChip(for: selected.status)
            compactChip(for: selected.sort)
            compactChip(for: selected.genre)
            Spacer(minLength: DesignTokens.Spacing.xxs)
            PageJumpButton(page: page, onJump: onJump)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func compactChip(for category: ExploreCategory) -> some View {
        Button(action: onExpand) {
            Text(category.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.FilterChip.hPadding)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .frame(minHeight: DesignTokens.Hit.minSize)
                .background(Capsule().fill(AppTheme.accent))
                .foregroundStyle(Color(uiColor: .systemBackground))
        }
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Capsule())))
        .accessibilityLabel("展开\(category.title)筛选")
    }
}

private struct ExploreCategoryFilterRow: View {
    let title: String
    let items: [ExploreCategory]
    let selectedItem: ExploreCategory
    let page: Int?
    let onJump: ((Int) -> Void)?
    let onSelect: (ExploreCategory) -> Void
    @State private var isExpanded = false

    /// 首行固定 3 个胶囊；「展开 / 收起」右对齐到行尾（「状态」行改为跳页按钮）。
    /// 展开只把剩余选项折到下一行，首行不变 ⇒ 按钮不移动。
    private static let firstRowCount = 3

    var body: some View {
        // 标签与胶囊之间不留额外间距（对齐 demo `.group` 无 gap、`.label` 宽 34 自带视觉留白）。
        HStack(alignment: .top, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.FilterChip.labelWidth, alignment: .leading)
                .frame(minHeight: DesignTokens.Hit.minSize, alignment: .center)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(firstRowItems) { category in
                        chip(for: category)
                    }
                }
                if isExpanded {
                    FlowLayout(spacing: DesignTokens.Spacing.xs) {
                        ForEach(overflowItems) { category in
                            chip(for: category)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let page, let onJump {
                PageJumpButton(page: page, onJump: onJump)
            } else if items.count > Self.firstRowCount {
                toggleButton
            }
        }
    }

    /// 首行固定的 3 个胶囊；选中项不在前 3 时，把最后一个换成选中项（保证选中可见）。
    private var firstRowItems: [ExploreCategory] {
        var visible = Array(items.prefix(Self.firstRowCount))
        guard items.count > Self.firstRowCount,
              let selected = items.first(where: { $0.value == selectedItem.value }),
              !visible.contains(selected)
        else {
            return visible
        }
        visible[visible.count - 1] = selected
        return visible
    }

    private var overflowItems: [ExploreCategory] {
        let firstRow = firstRowItems
        return items.filter { item in !firstRow.contains(item) }
    }

    private func chip(for category: ExploreCategory) -> some View {
        ExploreCategoryChip(
            title: category.title,
            isSelected: selectedItem.group == category.group
                && selectedItem.value == category.value,
            action: { onSelect(category) }
        )
    }

    private var toggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(isExpanded ? "收起" : "展开")
                .font(.subheadline.weight(.regular))
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.FilterChip.hPadding)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .frame(minWidth: DesignTokens.Hit.minSize, minHeight: DesignTokens.Hit.minSize)
                .background(Capsule().fill(AppTheme.Surface.card))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Capsule())))
        .accessibilityLabel(isExpanded ? "收起\(title)筛选" : "展开\(title)筛选")
    }
}

private struct ExploreCategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.FilterChip.hPadding)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .frame(minWidth: DesignTokens.Hit.minSize, minHeight: DesignTokens.Hit.minSize)
                .background(
                    Capsule().fill(isSelected ? AppTheme.accent : AppTheme.Surface.card)
                )
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
        }
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Capsule())))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 流式布局：子视图按自然宽度从左到右排，放不下折到下一行（对齐 demo 的 `flex-wrap: wrap`）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = DesignTokens.Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            currentX += size.width + spacing
            usedWidth = max(usedWidth, currentX - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX, currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
