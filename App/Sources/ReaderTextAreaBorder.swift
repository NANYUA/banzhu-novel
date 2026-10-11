import SwiftUI

/// 阅读页的「书籍正文边框标识」：正文盒四周一圈**红色虚线**，用来看清正文的位置极限在哪。
///
/// ## 🔴 判据：几何必须与**真实的正文盒**同源
/// 这一层**不自己算 padding**，只接受调用方从正文层**同一份来源**推出的**全量**内缩：
/// 1. **竖向** `insets.top / bottom` = `ReaderView.readerContentPaddings(inset:)` 的返回值，
///    与正文层那两条 `.padding(.top/.bottom, …)` **是同一份变量**；
///    并且 `PageTextView.textContainerInset` 的竖向恒为 `0`、
///    `TextKitMeasuring` 的容器高也不再扣竖向（竖向只有一套机制，B0-2 几何契约）
///    ⇒ 正文盒顶 = 内容盒顶、盒底 = 内容盒底。
/// 2. **横向** `insets.leading / trailing` = **横向安全区 + `PageInset.leading / trailing`**：
///    安全区那半来自正文层那两条 `.padding(.leading/.trailing, safeAreaInsets.…)`，
///    `PageInset` 那半来自 `PageTextView.textContainerInset` 的 left / right
///    （`TextKitMeasuring` 从 `containerSize.width` 里扣的是同两个值，渲染侧与度量侧同源）
///    ⇒ 正文盒左右 = 内容盒左右再各内缩这么多。
///
/// ## 为什么是**全量**内缩（而不是只补 `PageInset`）
/// 本层挂在正文层**四条 padding 之后** ⇒ 它拿到的 frame 是**整屏**
/// （`contentSize + 四条 padding` 正好还原整屏）⇒ 要落到正文盒上，
/// 补的必须是「**从屏幕边缘到正文盒**」的全量内缩。
/// 只补 `PageInset` 会漏掉横向安全区 —— 竖屏下横向安全区恒 0 时**碰巧**看不出问题，
/// 一旦支持横屏就会偏，而偏了就等于这个功能是假的。
///
/// ⛔ 因此这里**不许**出现 `78 - …` 之类的算式、也不许自己读 `PageInset` 再扣一遍：
/// 一旦公式分叉，标出来的就不是正文能排到的位置。
///
/// ## 叠加层性质（三条硬要求）
/// - `.allowsHitTesting(false)`：纯装饰，**不能吃掉翻页手势**（手势统一挂在外层，
///   见 `ReaderView.pageContent` 的 `readerGesture`）；
/// - `.accessibilityHidden(true)`：对读屏完全隐藏（它不承载任何信息，只给眼睛看）；
/// - 不占正文布局：它只画在正文盒的 frame 内，不改 padding / frame / 分页参数。
struct ReaderTextAreaBorder: ViewModifier {
    /// 是否显示（阅读设置里的开关，落盘在 `ReadingSettings.showsTextAreaBorder`）。
    let isOn: Bool

    /// **从屏幕边缘到正文盒**的全量内缩（由 `ReaderView` 从正文层的同一份来源推出，原样传入）。
    let insets: EdgeInsets

    /// 虚线样式：`1pt` 线宽 + `4 / 3` 的划长与间隙（划长 = `DesignTokens.Spacing.xxs`，
    /// 间隙比它短 1pt 让虚线更连续）。
    private static let strokeStyle = StrokeStyle(
        lineWidth: 1,
        dash: [DesignTokens.Spacing.xxs, DesignTokens.Spacing.xxs - 1]
    )

    func body(content: Content) -> some View {
        // ⚠️ 本层 frame = 整屏 ⇒ 用一次 `.padding(insets)` 把矩形收进正文盒，
        // 与正文层「先四条 padding 收内容盒、再由 `textContainerInset` 收左右」逐值同源。
        // `strokeBorder` 把 1pt 画在形状**内侧** ⇒ 线的最外沿正好落在正文盒边界上。
        content.overlay(alignment: .topLeading) {
            if isOn {
                Rectangle()
                    .strokeBorder(AppTheme.readerTextAreaBorder, style: Self.strokeStyle)
                    .padding(insets)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// 叠一层正文边框标识；`insets` 由调用方从**正文盒的同一份来源**推出
    /// （= 横向安全区 + `PageInset` 左右、`readerContentPaddings(inset:)` 上下）。
    func readerTextAreaBorder(isOn: Bool, insets: EdgeInsets) -> some View {
        modifier(ReaderTextAreaBorder(isOn: isOn, insets: insets))
    }
}
