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
public enum PageTurnMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// 左右滑动翻页
    case slide

    /// 点击左右区域翻页
    case tap

    /// 上下连续滚动
    case scroll
}

/// 翻页动画。
public enum PageTurnAnimation: String, CaseIterable, Hashable, Sendable, Codable {
    case none
    case cover
    case curl
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

    /// 默认四边 16pt：项目默认页边距（对齐设置面板滑杆 8…48 与 HIG 标准内容页边距 ≥16pt），
    /// 避免「从未动过阅读设置」时正文顶满屏幕（B0-4）。
    public init(top: CGFloat = 16, leading: CGFloat = 16, bottom: CGFloat = 16, trailing: CGFloat = 16) {
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
/// 影响分页：字体、字号、行距、段间距、字间距、加粗/倾斜、页边距、首行缩进。
/// 只影响渲染：背景色、文字颜色、亮度跟随、翻页方式、翻页动画、夜间模式。
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

    /// 首行缩进
    public var firstLineHeadIndent: CGFloat

    // MARK: - 只影响渲染的字段

    /// 背景色预置项
    public var backgroundStyle: ReadingBackgroundStyle

    /// 自定义背景色（`backgroundStyle == .custom` 时使用）
    public var customBackgroundColor: ReadingColor

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

    // MARK: - init

    /// 全字段初始化（结构体一次定型）。
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
        firstLineHeadIndent: CGFloat = 0,
        backgroundStyle: ReadingBackgroundStyle = .white,
        customBackgroundColor: ReadingColor = .defaultCustomBackground,
        textColorMode: ReadingTextColorMode = .automatic,
        customTextColor: ReadingColor = .defaultCustomText,
        followsSystemBrightness: Bool = true,
        pageTurnMode: PageTurnMode = .slide,
        pageTurnAnimation: PageTurnAnimation = .none,
        appearanceMode: ReadingAppearanceMode = .system
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
        self.firstLineHeadIndent = firstLineHeadIndent
        self.backgroundStyle = backgroundStyle
        self.customBackgroundColor = customBackgroundColor
        self.textColorMode = textColorMode
        self.customTextColor = customTextColor
        self.followsSystemBrightness = followsSystemBrightness
        self.pageTurnMode = pageTurnMode
        self.pageTurnAnimation = pageTurnAnimation
        self.appearanceMode = appearanceMode
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
            || firstLineHeadIndent != other.firstLineHeadIndent
    }
}
