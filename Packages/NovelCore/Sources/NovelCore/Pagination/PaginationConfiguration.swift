import CoreGraphics
import Foundation

/// 平台无关的颜色值。
///
/// `PaginationConfiguration` 位于纯逻辑层，不能依赖 UIKit / SwiftUI 的颜色类型。
/// 这里用红绿蓝加透明度四个通道保存，由 App 层负责映射成具体平台颜色。
public struct ReadingColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 预置颜色：白
    public static let white = ReadingColor(red: 1, green: 1, blue: 1)

    /// 预置颜色：黑
    public static let black = ReadingColor(red: 0, green: 0, blue: 0)

    /// 自定义背景色的默认值（米黄）
    public static let defaultCustomBackground = ReadingColor(red: 0.96, green: 0.93, blue: 0.84)

    /// 自定义文字色的默认值（深灰）
    public static let defaultCustomText = ReadingColor(red: 0.16, green: 0.16, blue: 0.16)
}

/// 阅读背景色预置项。
public enum ReadingBackgroundStyle: String, CaseIterable, Hashable, Sendable, Codable {
    case white
    case sepia
    case eyeCare
    case black
    case custom
}

/// 文字颜色策略。
public enum ReadingTextColorMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// 根据背景亮度自动选择黑或白
    case automatic

    /// 使用 `customTextColor`
    case custom
}

/// 夜间模式 / 外观模式。
public enum ReadingAppearanceMode: String, CaseIterable, Hashable, Sendable, Codable {
    case system
    case light
    case dark
}

/// 翻页方式。
///
/// 只保留左右滑动：`tap`（点击左右区域翻页）与 `scroll`（上下连续滚动）已删除
/// （owner 决定，阅读界面改版）。
public enum PageTurnMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// 左右滑动翻页
    case slide
}

/// 翻页动画。
///
/// 只保留 `none`：`cover` 与 `curl` 已删除（owner 决定，阅读界面改版）。
public enum PageTurnAnimation: String, CaseIterable, Hashable, Sendable, Codable {
    case none
}

/// 分页所需的内边距（零 UI 依赖，纯值类型）。
///
/// 不用 `UIEdgeInsets`（UIKit，macOS host 上不存在）也不用 SwiftUI `EdgeInsets`
/// （把纯逻辑层跟 UI 框架绑死）。自定义结构体，四个 CGFloat。
///
/// ## 可见性
/// `public`：`TextKitMeasuring`（NovelPagination 包）要实现分页时需要这些类型，
/// 跨包可见才能用它。
public struct PageInset: Equatable, Sendable, Codable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    /// 默认：左右 **24pt**、上下 **78 / 30pt**（竖向**不对称** —— 上下各有自己的滑杆）。
    ///
    /// ## 新语义：`top` / `bottom` = **距屏幕边缘的绝对距离**（2026-10-11，owner 口径）
    /// - `0` = 正文贴到**屏幕最边缘**，**不自己适配刘海 / 灵动岛**（内容可以被缺口盖住
    ///   —— owner 明确要这个行为）；`78` = 距屏幕上边 78pt。
    /// - 范围：上 **0 … 200**、下 **0 … 120**（设置页两个滑杆各自只改自己那一侧）。
    /// - 默认 78 / 30 都在范围内，且能被滑杆步长 2 精确取到。
    /// - **为什么改成绝对距离**：旧语义是「相对安全区的偏移」，同一个读数在安全区顶 59 的
    ///   灵动岛机型和 47 的刘海屏机型上落到完全不同的位置（差 12pt）；owner 要的是
    ///   「正文距屏幕边多少就是多少」的可预期手感。代价是 `0` 附近不再自动避让缺口。
    ///
    /// ## 实现：竖向边距**只有一套机制**
    /// 由 SwiftUI 层的布局 padding 兑现（`ReaderView.readerContentPaddings`，盒高与它同源）。
    /// `PageTextView.textContainerInset` 与 `TextKitMeasuring` 的竖向一律按 **0** 处理 ——
    /// 两处都算就是边距翻倍、且分页与渲染错位（B0-2）。
    /// 左右（`leading` / `trailing`）**语义未变**：正值是「安全区盒内再减的左右边距」，
    /// 由 `textContainerInset` 的 left / right 兑现，默认 24（U1-8，owner 指定）比 HIG 的
    /// 16pt 底线更宽松：中文正文一行排得下的字数更舒服，也避开屏幕圆角。
    ///
    /// ## 历史（已废弃，保留是为了看懂老 JSON / 老注释）
    /// U9-7 的默认值是 **-18 / -18**：那时 `top` / `bottom` 是「**相对安全区向屏幕边缘推**的
    /// 偏移量」，负值不是「减掉边距」而是把正文盒往屏幕边推（由 SwiftUI 层放大盒子兑现），
    /// 传给 TextKit 的竖向 inset 一律 clamp 到 `>= 0`。新语义下**负值无意义**
    /// （`-18` 会被读成「屏幕外 18pt」）⇒ 已存数据由 `VerticalInsetDefaultMigration`
    /// （key `reader.insetDefaultMigrated.v3`）一次性重置为新默认。
    public init(top: CGFloat = 78, leading: CGFloat = 24, bottom: CGFloat = 30, trailing: CGFloat = 24) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// 分页配置。
///
/// ## 为什么一次定义完整
/// 阅读设置一次定型，避免每加一个控件都改类型、改 init、改测试。
///
/// ## 影响分页与只影响渲染的字段
/// 影响分页：字体、字号、行距、段间距、字间距、加粗/倾斜、页边距、首行缩进开关。
/// 只影响渲染：背景色、文字颜色、亮度跟随、翻页方式、翻页动画、夜间模式、角落标签边距。
///
/// `affectsPagination(comparedTo:)` 用来区分这两类，避免改背景色也重排整章。
public struct PaginationConfiguration: Equatable, Sendable {
    // MARK: - 参与分页的字段

    /// 一页可排文字的容器尺寸（不含内边距的净宽高）
    public var containerSize: CGSize

    /// 字号（pt）
    public var fontSize: CGFloat

    /// 行距（行与行的额外距离）
    public var lineSpacing: CGFloat

    /// 页边距（上下左右留白）
    public var inset: PageInset

    /// 字体名。nil = 系统字体
    public var fontName: String?

    /// 段间距
    public var paragraphSpacing: CGFloat

    /// 字间距
    public var characterSpacing: CGFloat

    /// 字体加粗
    public var isBold: Bool

    /// 字体倾斜
    public var isItalic: Bool

    /// 是否打开首行缩进（owner 口径：**默认打开**）。
    public var isFirstLineIndentOn: Bool

    /// 首行缩进宽度：由 `isFirstLineIndentOn` 与 `fontSize` **派生**（2 个字符宽，与旧实现逐值一致）。
    ///
    /// 派生而不是各存一份：两份状态一旦不同步就会出现「开关开着但缩进是 0」这种自相矛盾的配置
    /// （旧实现靠设置页在改字号时手动同步，漏一处就漂）。它仍是排版层的公开读接口
    /// （`PageTextView` / `TextKitMeasuring` 直接读它），调用方不需要知道开关。
    public var firstLineHeadIndent: CGFloat {
        isFirstLineIndentOn ? fontSize * 2 : 0
    }

    // MARK: - 只影响渲染的字段

    /// 背景色预置项
    public var backgroundStyle: ReadingBackgroundStyle

    /// 自定义背景色（`backgroundStyle == .custom` 时使用，亮色外观）
    public var customBackgroundColor: ReadingColor

    /// 自定义背景色的暗色版本（`backgroundStyle == .custom` 且暗色外观时使用）
    public var customBackgroundColorDark: ReadingColor

    /// 文字颜色策略
    public var textColorMode: ReadingTextColorMode

    /// 自定义文字颜色（`textColorMode == .custom` 时使用）
    public var customTextColor: ReadingColor

    /// 亮度是否跟随系统
    public var followsSystemBrightness: Bool

    /// 翻页方式
    public var pageTurnMode: PageTurnMode

    /// 翻页动画
    public var pageTurnAnimation: PageTurnAnimation

    /// 夜间模式 / 外观模式
    public var appearanceMode: ReadingAppearanceMode

    /// 角落状态标签（左上书名 / 章节名、左下电量、右下页码）距**屏幕左右边缘**的距离（pt）。
    ///
    /// 三个标签**共用**这一个值：`ReaderCornerHUD` 的一条 `.padding(.horizontal, …)`
    /// 同时管住左上 / 左下 / 右下。默认 `16` = App 层尺度令牌 `DesignTokens.Spacing.md`
    /// （NovelCore 不能 import SwiftUI / DesignTokens，故此处写同值，
    /// `ReadingSettingsStoreTests` 有一条「两处默认值同源」的锚点测试）。
    ///
    /// **只影响渲染**：不进 `affectsPagination` ⇒ 拖这个滑杆不重排正文、不动阅读位置。
    public var hudHorizontalInset: CGFloat

    /// 上栏面板**上边缘距屏幕顶**的距离（pt）。
    ///
    /// **绝对值语义**：`0` = 贴屏幕最边缘（**不避让灵动岛**，owner 口径）。
    ///
    /// `nil` = **自动**：由 App 层按安全区解析成 `max(Spacing.xs, 安全区top − 34)`
    /// —— 那正是各机型的「当前自动值」（灵动岛机型约 25pt、无刘海机型 8pt）。
    /// ⚠️ 所以**默认 `nil` 就等于改造前的行为**，不需要迁移 key。
    /// ⚠️ 为什么「自动」必须留在 App 层：NovelCore 拿不到安全区（那是 UIKit / SwiftUI 的事）。
    ///
    /// **只影响渲染**：不进 `affectsPagination` ⇒ 拖这个滑杆不重排正文、不动阅读位置
    /// （控制栏是叠加层，不占正文布局）。
    public var topBarInset: CGFloat?

    /// 下栏面板**下边缘距屏幕底**的距离（pt）。
    ///
    /// **绝对值语义**：`0` = 贴屏幕最边缘。
    ///
    /// 默认 `8` = App 层尺度令牌 `DesignTokens.Spacing.xs`（NovelCore 不能 import SwiftUI /
    /// `DesignTokens`，故此处写同值）—— 那个值就是改造前的固定值 ⇒ **默认行为零变化**。
    ///
    /// **只影响渲染**：不进 `affectsPagination`（理由同上）。
    public var bottomBarInset: CGFloat

    // MARK: - init

    /// 全字段初始化（结构体一次定型）。
    ///
    /// ⚠️ 没有 `firstLineHeadIndent` 参数：缩进宽度由 `isFirstLineIndentOn` + `fontSize` 派生
    /// （见该属性的文档），传进来一份独立值只会与开关脱节。
    public init(
        containerSize: CGSize,
        fontSize: CGFloat = 17,
        lineSpacing: CGFloat = 4,
        inset: PageInset = PageInset(),
        fontName: String? = nil,
        paragraphSpacing: CGFloat = 6,
        characterSpacing: CGFloat = 0,
        isBold: Bool = false,
        isItalic: Bool = false,
        isFirstLineIndentOn: Bool = true,
        backgroundStyle: ReadingBackgroundStyle = .white,
        customBackgroundColor: ReadingColor = .defaultCustomBackground,
        customBackgroundColorDark: ReadingColor = .defaultCustomBackground,
        textColorMode: ReadingTextColorMode = .automatic,
        customTextColor: ReadingColor = .defaultCustomText,
        followsSystemBrightness: Bool = true,
        pageTurnMode: PageTurnMode = .slide,
        pageTurnAnimation: PageTurnAnimation = .none,
        appearanceMode: ReadingAppearanceMode = .system,
        hudHorizontalInset: CGFloat = 16,
        topBarInset: CGFloat? = nil,
        bottomBarInset: CGFloat = 8
    ) {
        self.containerSize = containerSize
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.inset = inset
        self.fontName = fontName
        self.paragraphSpacing = paragraphSpacing
        self.characterSpacing = characterSpacing
        self.isBold = isBold
        self.isItalic = isItalic
        self.isFirstLineIndentOn = isFirstLineIndentOn
        self.backgroundStyle = backgroundStyle
        self.customBackgroundColor = customBackgroundColor
        self.customBackgroundColorDark = customBackgroundColorDark
        self.textColorMode = textColorMode
        self.customTextColor = customTextColor
        self.followsSystemBrightness = followsSystemBrightness
        self.pageTurnMode = pageTurnMode
        self.pageTurnAnimation = pageTurnAnimation
        self.appearanceMode = appearanceMode
        self.hudHorizontalInset = hudHorizontalInset
        self.topBarInset = topBarInset
        self.bottomBarInset = bottomBarInset
    }

    /// 判断这次配置变化是否需要重新分页。
    ///
    /// 背景色、文字颜色、翻页方式等只影响渲染，跳过重排可以避免无意义的开销。
    public func affectsPagination(comparedTo other: PaginationConfiguration) -> Bool {
        containerSize != other.containerSize
            || fontSize != other.fontSize
            || lineSpacing != other.lineSpacing
            || inset != other.inset
            || fontName != other.fontName
            || paragraphSpacing != other.paragraphSpacing
            || characterSpacing != other.characterSpacing
            || isBold != other.isBold
            || isItalic != other.isItalic
            || isFirstLineIndentOn != other.isFirstLineIndentOn
    }
}
