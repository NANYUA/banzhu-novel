/// 站点发现页的筛选目录。
///
/// URL 由「状态-排序-题材-页码」四段组成；状态、排序和题材分别是独立筛选维度。
public enum ExploreCategoryCatalog {
    public static let statuses: [ExploreCategory] = [
        item("全部", status: "0"),
        item("连载中", status: "1"),
        item("已完本", status: "2"),
    ]

    public static let sorts: [ExploreCategory] = [
        item("最新更新", sort: "lastupdate"),
        item("总人气", sort: "allvisit"),
        item("月人气", sort: "monthvisit"),
        item("字数", sort: "size"),
        item("新书", sort: "postdate"),
    ]

    public static let genres: [ExploreCategory] = [
        item("全部", genre: "0"),
        item("玄幻奇幻", genre: "1"),
        item("武侠仙侠", genre: "2"),
        item("都市言情", genre: "3"),
        item("穿越历史", genre: "4"),
        item("科幻灵异", genre: "5"),
        item("藏经阁", genre: "6"),
        item("其他类别", genre: "7"),
    ]

    public static let allItems = statuses + sorts + genres

    public static let defaultCategory = category(
        status: statuses[0],
        sort: sorts[0],
        genre: genres[0]
    )

    public static func category(status: ExploreCategory, sort: ExploreCategory, genre: ExploreCategory) -> ExploreCategory {
        let statusValue = status.value ?? "0"
        let sortValue = sort.value ?? "lastupdate"
        let genreValue = genre.value ?? "0"
        return ExploreCategory(
            title: "\(status.title) · \(sort.title) · \(genre.title)",
            urlTemplate: "/shuku/\(statusValue)-\(sortValue)-\(genreValue)-{{page}}.html",
            value: "\(statusValue)|\(sortValue)|\(genreValue)"
        )
    }

    private static func item(_ title: String, status: String) -> ExploreCategory {
        ExploreCategory(title: title, urlTemplate: "", group: .status, value: status)
    }

    private static func item(_ title: String, sort: String) -> ExploreCategory {
        ExploreCategory(title: title, urlTemplate: "", group: .sort, value: sort)
    }

    private static func item(_ title: String, genre: String) -> ExploreCategory {
        ExploreCategory(title: title, urlTemplate: "", group: .genre, value: genre)
    }
}
