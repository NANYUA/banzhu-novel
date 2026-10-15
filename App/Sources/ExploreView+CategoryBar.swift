import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

extension ExploreView {
    /// 三个筛选维度各占一行；空间不足时可单独展开该组的全部选项。
    /// 跳页按钮并入「状态」行末（右对齐），点击弹输入框跳指定页码。
    func categoryBar(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
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
                }
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
}

private struct ExploreCategoryFilterRow: View {
    let title: String
    let items: [ExploreCategory]
    let selectedItem: ExploreCategory
    let page: Int?
    let onJump: ((Int) -> Void)?
    let onSelect: (ExploreCategory) -> Void
    @State private var isExpanded = false

    /// 展开态第一行保留的胶囊数（不含「收起」按钮）。
    ///
    /// demo 稿固定 3 个（14px 字号 / 392px 宽度）；本 App 统一 `.subheadline`（15pt）
    /// 加 `Spacing.md` 内边距后，标准 iPhone 宽度只放得下 2 个胶囊 + 「收起」（3 个会溢出），
    /// 故取 2，与收起态在标准宽度下实际能放下的胶囊数一致。
    private static let expandedFirstRowCount = 2

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Hit.minSize, alignment: .leading)
                .frame(minHeight: DesignTokens.Hit.minSize, alignment: .center)

            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }

            if let page, let onJump {
                Spacer(minLength: DesignTokens.Spacing.xxs)
                PageJumpButton(page: page, onJump: onJump)
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(firstRowItems) { category in
                    chip(for: category)
                }
                toggleButton
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: DesignTokens.Hit.minSize * 2), spacing: DesignTokens.Spacing.xs)],
                alignment: .leading,
                spacing: DesignTokens.Spacing.xs
            ) {
                ForEach(overflowItems) { category in
                    chip(for: category, allowsWrapping: true)
                }
            }
        }
    }

    private var collapsedContent: some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1 ... items.count).reversed(), id: \.self) { visibleCount in
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(collapsedItems(visibleCount: visibleCount)) { category in
                        chip(for: category)
                    }
                    if visibleCount < items.count {
                        toggleButton
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                chip(for: selectedItem, allowsWrapping: true)
                toggleButton
            }
        }
    }

    private var firstRowItems: [ExploreCategory] {
        collapsedItems(visibleCount: Self.expandedFirstRowCount)
    }

    private var overflowItems: [ExploreCategory] {
        let firstRow = firstRowItems
        return items.filter { item in !firstRow.contains(item) }
    }

    private func collapsedItems(visibleCount: Int) -> [ExploreCategory] {
        var visible = Array(items.prefix(visibleCount))
        guard visibleCount < items.count else { return visible }
        guard let selected = items.first(where: { $0.value == selectedItem.value }) else { return visible }
        guard !visible.contains(selected) else { return visible }
        visible[visible.count - 1] = selected
        return visible
    }

    private func chip(for category: ExploreCategory, allowsWrapping: Bool = false) -> some View {
        ExploreCategoryChip(
            title: category.title,
            isSelected: selectedItem.group == category.group
                && selectedItem.value == category.value,
            allowsWrapping: allowsWrapping,
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
                .padding(.horizontal, DesignTokens.Spacing.md)
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
    let allowsWrapping: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(allowsWrapping ? nil : 1)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .frame(minWidth: DesignTokens.Hit.minSize, minHeight: DesignTokens.Hit.minSize)
                .frame(maxWidth: allowsWrapping ? .infinity : nil)
                .background(
                    Capsule().fill(isSelected ? AppTheme.accent : AppTheme.Surface.card)
                )
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
        }
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Capsule())))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
