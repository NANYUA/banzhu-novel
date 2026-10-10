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

    /// 默认：左右 **24pt**、上下 **-18 / -18pt**（竖向**对称**）。
    ///
    /// - 左右 24（U1-8，owner 指定）比 HIG 的 16pt 底线更宽松：中文正文一行排得下的字数更舒服，
    ///   也避开屏幕圆角。
    /// - 上下 **-18 / -18**（U9-7，owner 真机反馈「距离屏幕上下太远」）：
    ///   **负值不是「减掉边距」，而是「相对安全区向屏幕边缘推的偏移量」**。
    ///   此前是 0（U9-3b），正文正好贴在安全区边界上 —— 而状态栏已隐藏，安全区顶那几十 pt
    ///   是纯留白（量测：屏幕顶到章标题首字形 72px = 安全区顶 59 + 行高留白 ~13）。
    ///   - **竖向默认值必须对称**：设置面板只有**一个**「上下边距」滑杆，
    ///     `verticalInsetBinding` 一次同时写 `top` 与 `bottom` ⇒ 默认值不对称时，
    ///     `bottom` 会落在滑杆范围之外（例：`bottom = -22` 配下限 `-18`），用户一拖就被夹到下限、
    ///     下边缘凭空上移；滑杆读数（`Int(inset.top)`）也代表不了实际的下边距。
    ///   - `-18`（上）：盒顶上移到安全区顶之上 18pt，首行**字形**顶 ≈ 安全区顶 − 18 + 13（首行留白）：
    ///     - 灵动岛机型（安全区顶 59、缺口下沿 48）：59 − 18 + 13 = 54 ⇒ 余量 **6pt**；
    ///     - 刘海屏机型（安全区顶 ~47、缺口下沿 ~33）：47 − 18 + 13 = 42 ⇒ 余量 **9pt**。
    ///     两种缺口机型都有可感知余量。此前取的 `-24` 只按灵动岛推导（59 − 24 + 13 = 48，
    ///     余量 0pt），换到刘海屏只剩约 3pt —— 而「首行行高留白 13pt」本身是量测**估算值**，
    ///     ±3pt 就会让首行被缺口盖住（正文整行满宽，躲不开），故必须留余量、收到 `-18`。
    ///   - `-18`（下）：下边距的安全极限约 `-34`（屏幕底往上约 5pt 的 Home Indicator 细条），
    ///     `-18` 让末行离屏幕底约 16pt，比原来的 `-22`（约 12pt）更宽裕。
    ///   负值由 SwiftUI 层**放大盒子**实现（`ReaderView.readerContentSize`）——
    ///   传给 TextKit 的竖向 inset 一律 clamp 到 `>= 0`（`UITextView.clipsToBounds` 默认 true，
    ///   负 inset 只会把正文裁掉而不是往外扩）。
    ///   滑杆范围 `-18 ... 48` 恰好覆盖这个下限（全机型都不会让首行被缺口盖住），
    ///   用户仍可自己调回 0 或加正边距。
    public init(top: CGFloat = -18, leading: CGFloat = 24, bottom: CGFloat = -18, trailing: CGFloat = 24) {
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
        customBackgroundColorDark: ReadingColor = .defaultCustomBackground,
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
        self.customBackgroundColorDark = customBackgroundColorDark
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
