import CoreGraphics
import Foundation

/// 分页所需的内边距（零 UI 依赖，纯值类型）。
///
/// 不用 `UIEdgeInsets`（UIKit，macOS host 上不存在）也不用 SwiftUI `EdgeInsets`
/// （把纯逻辑层跟 UI 框架绑死）。自定义结构体，四个 CGFloat。
///
/// ## 可见性
/// `public`：`TextKitMeasuring`（NovelPagination 包）要实现分页时需要这些类型，
/// 跨包可见才能用它。
public struct PageInset: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// 分页配置。
///
/// ## 为什么一次定义完整（14 项影响分页的字段全放）
/// docs/03 §4.1 定了 14 项阅读设置，其中 docs/04 明确指出**影响分页结果**的是：
/// 字号、行距、段间距、页边距、首行缩进。
/// 但「结构体定型」和「真正参与分页」是两件事：
/// - **结构体一次定义完整**：避免后续每次加一个设置都要改类型、改 init、改测试
/// - **本轮只实现参与分页的最小字段**：其余字段给默认值占位，等后续迭代真正用上
///
/// ## 本轮真正参与分页的字段
/// `containerSize`（页面几何）+ `fontSize`（字号）+ `lineSpacing`（行距）
/// + `inset`（页边距）—— 这是 `Paginator` 算每页字符数的输入。
/// 其余字段（段间距/首行缩进/字间距/字体等）定义了但不读，留待后续。
public struct PaginationConfiguration: Equatable, Sendable {
    // MARK: - 本轮参与分页的最小字段

    /// 一页可排文字的容器尺寸（不含内边距的净宽高）
    public var containerSize: CGSize

    /// 字号（pt）
    public var fontSize: CGFloat

    /// 行距（行与行的额外距离）
    public var lineSpacing: CGFloat

    /// 页边距（上下左右留白）
    public var inset: PageInset

    // MARK: - 已定义但本轮不参与分页的字段（占位，留待后续迭代）

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

    // MARK: - init

    /// 全字段初始化（结构体一次定型）。
    /// 本轮从最小字段开始，其余给默认值。
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
        firstLineHeadIndent: CGFloat = 0
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
    }
}
