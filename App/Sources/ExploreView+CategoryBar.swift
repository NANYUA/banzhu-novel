import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

extension ExploreView {
    /// 三个筛选维度各占一行；每组首行固定 3 个胶囊，行尾右对齐「展开 / 收起」
    /// （「状态」行行尾改为跳页按钮），两者右边缘对齐；展开后其余选项折到下一行。
    /// 跳页按钮点击弹输入框跳指定页码。
    /// 滚动时按 `collapseProgress`（0 完整 / 1 收缩）把完整栏收缩成
    /// 一行「3 个选中值 + 跳页按钮」：收缩态胶囊从「状态」行上方下滑、
    /// 用不透明底色覆盖第一排，对齐 `ui-mockups/explore-page.html` 的收缩态。
    func categoryBar(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>,
        collapseProgress: Double,
        onExpand: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            ExploreCategoryFilters(
                categories: viewStore.categories,
                selectedCategory: viewStore.selectedCategory,
                page: viewStore.page,
                onJump: { page in
                    viewStore.send(.jumpToPage(page))
                },
                onSelect: { category in
                    viewStore.send(.categorySelected(category))
                },
                collapseProgress: collapseProgress,
                onExpand: onExpand
            )
            Divider()
        }
        .background(AppTheme.Surface.page)
    }
}

private struct ExploreCategoryFilters: View {
    let categories: [ExploreCategory]
    let selectedCategory: ExploreCategory?
    let page: Int
    let onJump: (Int) -> Void
    let onSelect: (ExploreCategory) -> Void
    let collapseProgress: Double
    let onExpand: () -> Void

    @State private var fullBarHeight: CGFloat = 0
    @State private var compactBarHeight: CGFloat = 0

    private var selectedStatus: ExploreCategory {
        option(in: ExploreCategoryCatalog.statuses, defaultIndex: 0)
    }

    private var selectedSort: ExploreCategory {
        option(in: ExploreCategoryCatalog.sorts, defaultIndex: 0)
    }

    private var selectedGenre: ExploreCategory {
        option(in: ExploreCategoryCatalog.genres, defaultIndex: 0)
    }

    private func option(in options: [ExploreCategory], defaultIndex: Int) -> ExploreCategory {
        guard let value = selectedCategory?.value?.split(separator: "|").map(String.init),
              value.count == 3
        else {
            return options[defaultIndex]
        }
        let selectedValue: String
        switch options.first?.group {
        case .status: selectedValue = value[0]
        case .sort: selectedValue = value[1]
        case .genre: selectedValue = value[2]
        default: return options[defaultIndex]
        }
        return options.first(where: { $0.value == selectedValue }) ?? options[defaultIndex]
    }

    private func selectedItem(for group: ExploreCategoryGroup) -> ExploreCategory {
        switch group {
        case .status: selectedStatus
        case .sort: selectedSort
        case .genre: selectedGenre
        case .legacy: ExploreCategoryCatalog.defaultCategory
        }
    }

    private func select(_ item: ExploreCategory) {
        let status = item.group == .status ? item : selectedStatus
        let sort = item.group == .sort ? item : selectedSort
        let genre = item.group == .genre ? item : selectedGenre
        onSelect(ExploreCategoryCatalog.category(status: status, sort: sort, genre: genre))
    }

    private var visibleGroups: [ExploreCategoryGroup] {
        ExploreCategoryGroup.allCases.filter { group in
            group != .legacy && categories.contains(where: { $0.group == group })
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            fullBar
                .allowsHitTesting(collapseProgress < 0.5)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    guard height > 0 else { return }
                    fullBarHeight = height
                }
            compactBar
                .background(AppTheme.Surface.page)
                .offset(y: -(1 - compactBarOpacity) * compactBarHeight)
                .opacity(compactBarOpacity)
                .allowsHitTesting(collapseProgress >= 0.5)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    guard height > 0 else { return }
                    compactBarHeight = height
                }
        }
        .frame(height: interpolatedHeight, alignment: .top)
        .clipped()
        .background(AppTheme.Surface.page)
    }

    /// 收缩栏淡入：`collapseProgress` 0.25→0.625 内从 0 升到 1；
    /// 同时从「状态」行上方（offset = −自身高度）下滑到原位。
    private var compactBarOpacity: Double {
        min(max((collapseProgress - 0.25) / 0.375, 0), 1)
    }

    /// 完整栏与收缩栏高度之间线性插值；首次测量完成前不约束高度（自然高度）。
    private var interpolatedHeight: CGFloat? {
        guard fullBarHeight > 0, compactBarHeight > 0 else {
            return nil
        }
        return fullBarHeight - CGFloat(collapseProgress) * (fullBarHeight - compactBarHeight)
    }

    private var fullBar: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            ForEach(visibleGroups, id: \.self) { group in
                ExploreCategoryFilterRow(
                    title: group.title,
                    items: categories.filter { $0.group == group },
                    selectedItem: selectedItem(for: group),
                    page: group == .status ? page : nil,
                    onJump: group == .status ? onJump : nil,
                    onSelect: select
                )
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private var compactBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            compactChip(for: selectedStatus)
            compactChip(for: selectedSort)
            compactChip(for: selectedGenre)
            Spacer(minLength: DesignTokens.Spacing.xxs)
            PageJumpButton(page: page, onJump: onJump)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    /// 收缩态的单个选中胶囊：点击整颗展开回完整栏（不切换选择，对应 demo 的「手动展开」）。
    /// 用选中态配色（accent 底 + 反色文字），对齐 demo 收缩栏的 `.chip.selected`。
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
