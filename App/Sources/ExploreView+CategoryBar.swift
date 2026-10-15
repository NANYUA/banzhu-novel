import ComposableArchitecture
import NovelCore
import NovelEngine
import SwiftUI

extension ExploreView {
    /// 三个筛选维度各占一行；空间不足时可单独展开该组的全部选项。
    func categoryBar(
        _ viewStore: ViewStore<ExploreFeature.State, ExploreFeature.Action>
    ) -> some View {
        VStack(spacing: 0) {
            ExploreCategoryFilters(
                categories: viewStore.categories,
                selectedCategory: viewStore.selectedCategory,
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
    let onSelect: (ExploreCategory) -> Void
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Hit.minSize, alignment: .leading)
                .frame(minHeight: DesignTokens.Hit.minSize, alignment: .center)

            if isExpanded {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: DesignTokens.Hit.minSize * 2), spacing: DesignTokens.Spacing.xs)],
                    alignment: .leading,
                    spacing: DesignTokens.Spacing.xs
                ) {
                    ForEach(items) { category in
                        chip(for: category, allowsWrapping: true)
                    }
                    toggleButton
                }
            } else {
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
        }
    }

    private func collapsedItems(visibleCount: Int) -> [ExploreCategory] {
        var visible = Array(items.prefix(visibleCount))
        if visibleCount < items.count, let selected = items.first(where: { $0.value == selectedItem.value }),
           !visible.contains(selected)
        {
            visible[visible.count - 1] = selected
        }
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
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text(isExpanded ? "收起" : "展开")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .frame(minWidth: DesignTokens.Hit.minSize, minHeight: DesignTokens.Hit.minSize)
            .background(Capsule().fill(AppTheme.Surface.card))
        }
        .buttonStyle(PressableCardButtonStyle(shape: AnyShape(Capsule())))
        .foregroundStyle(AppTheme.accent)
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
