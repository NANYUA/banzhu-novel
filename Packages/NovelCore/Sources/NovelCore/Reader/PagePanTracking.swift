import CoreGraphics

/// 平移翻页的判页结果：**一次最多一页**，所以是枚举，而不是「跳几页」的整数。
public enum PagePanTurn: Equatable, Sendable {
    /// 原地滑回本页。
    case none
    /// 翻到下一页。
    case next
    /// 翻到上一页。
    case previous
}

/// 一页的几何上下文：页宽 + 当前页下标 + 总页数。
///
/// 这三个值在判页里**永远一起出现、一起被读**：页宽定出屏幕中线，下标与总页数定出
/// 首 / 末页边界。收成一个值类型而不是三个并列参数，有两个好处：
/// 1. 「它们描述的是同一次手势里的同一页」这层语义落到类型上，调用点不会把顺序摆错；
/// 2. `turn` 的参数个数守在 SwiftLint `function_parameter_count` 的 5 个以内。
///
/// 值类型：只装数据、没有身份，`Equatable` 便于测试里直接比对两个几何。
public struct PagePanGeometry: Equatable, Sendable {
    /// 阅读区可用宽度 —— 也就是**一页**的宽（`0` 是退化盒子，见 `crossesScreenMidline`）。
    public var availableWidth: CGFloat
    /// 当前页下标。
    public var pageIndex: Int
    /// 总页数。
    public var pageCount: Int

    public init(availableWidth: CGFloat, pageIndex: Int, pageCount: Int) {
        self.availableWidth = availableWidth
        self.pageIndex = pageIndex
        self.pageCount = pageCount
    }
}

/// 阅读页「平移翻页」（全景图式左右平移）的纯数学，CI 可测。
///
/// ## 与 `SlideTracking` 的分工
/// `SlideTracking` 管的是「**一页**怎么跟手」：抓取基线 + 本次位移 → 页面偏移，含边界橡皮筋。
/// 本类型在它之上只补两条「平移」特有的规则，**不改它一行**：
/// 1. **单页约束**（`panOffset`）：全景图只铺相邻两页，位移夹在一页之内；
/// 2. **中线判据**（`turn`）：松手后两页的中线是否越过屏幕中线，决定翻页还是滑回本页。
///
/// 跟手基线、边界橡皮筋、动量投射的既有口径全部沿用 `SlideTracking` / U0-8 ——
/// 那是 owner 已验收的行为，这里只做「覆盖 → 平移」这一处口径替换。
///
/// ## 为什么单独抽出来
/// 这段算法原来（以及如果不抽出来就会）活在 View 的手势闭包与 `@State` 之间，
/// 全仓零测试 —— 算错了只有真机手感能发现。抽成纯函数后，
/// 「单页约束」「中线判据」这两条新规则才由 CI 兜住（先例：`TextCursor`、`SlideTracking`）。
///
/// ⚠️ 只依赖 `CGFloat`（CoreGraphics），不 import SwiftUI / UIKit ——
/// `scripts/check-architecture.sh` 规则 1 禁止 `Packages/` 引用 UI 框架。
public enum PagePanTracking {
    /// 本次手势跟手后，全景图应当显示的横向偏移（一次最多一页）。
    ///
    /// - Parameters:
    ///   - displayedOffset: **抓取瞬间页面真实显示**的偏移（吸附动画进行中即呈现值）。
    ///   - translation: 本次手势的 `DragGesture.Value.translation.width`。
    ///   - availableWidth: 阅读区可用宽度 —— 也就是**一页**的宽。
    ///   - pageIndex: 当前页下标。
    ///   - pageCount: 总页数。
    /// - Returns: 全景图此刻应显示的偏移，恒在 `[-availableWidth, availableWidth]` 内。
    public static func panOffset(
        fromDisplayedOffset displayedOffset: CGFloat,
        translation: CGFloat,
        availableWidth: CGFloat,
        pageIndex: Int,
        pageCount: Int
    ) -> CGFloat {
        let tracked = SlideTracking.offset(
            fromDisplayedOffset: displayedOffset,
            translation: translation,
            availableWidth: availableWidth,
            pageIndex: pageIndex,
            pageCount: pageCount
        )
        // 单页约束：全景图只铺「当前页 + 相邻一页」，夹在一页宽内就不会露出第三页或底色。
        // 文档首尾那一支（`SlideTracking` 的橡皮筋）结果恒在一页宽内，本句对它不产生任何改变
        // —— 边界橡皮筋是已验收手感，未被这条约束覆盖。
        return min(max(tracked, -availableWidth), availableWidth)
    }

    /// 松手后的落点：跟手位移 + **剩余**动量投射。
    ///
    /// `predictedEndTranslation` 是**相对本次手势起点**的总位移，所以要减掉已经跟手走掉的
    /// `translation`，只把剩余那段动量加到跟手位移上。基线为 0 时化简为
    /// `predictedEndTranslation` —— 与 U0-8 已验收的动量判向逐值一致。
    static func settledOffset(
        trackedOffset: CGFloat,
        translation: CGFloat,
        predictedEndTranslation: CGFloat
    ) -> CGFloat {
        trackedOffset + (predictedEndTranslation - translation)
    }

    /// 中线判据：两页的中线（两页**共享的那条边**）是否越过屏幕中线。
    ///
    /// 当前页偏移 `d`、页宽 `W` 时：
    /// - 向左拖（`d < 0`）：当前页 `[d, d+W]`、下一页 `[d+W, d+2W]`，共享边落在 `d+W`；
    ///   越过屏幕中线 `W/2` ⟺ `d + W < W/2` ⟺ `d < -W/2`；
    /// - 向右拖（`d > 0`）：上一页 `[d-W, d]`、当前页 `[d, d+W]`，共享边落在 `d`；
    ///   越过 ⟺ `d > W/2`。
    ///
    /// 两种情形化简后是同一个式子：**`|d| > W/2`** —— 这里就写化简式，
    /// 「共享边」那两种写法由 `PagePanTrackingTests` 钉住等价性。
    static func crossesScreenMidline(offset: CGFloat, availableWidth: CGFloat) -> Bool {
        guard availableWidth > 0 else { return false }
        return abs(offset) > availableWidth / 2
    }

    /// 松手后该翻哪一页。
    ///
    /// - 中线未越过屏幕中线 → `.none`（滑回本页）；
    /// - 越过 → 按落点方向翻**一页**；已在首 / 末页则退化为 `.none`（原地滑回）。
    ///
    /// - Parameters:
    ///   - trackedOffset: 本次手势跟手后的偏移（`panOffset` 的结果）。
    ///   - translation: 本次手势的 `DragGesture.Value.translation.width`。
    ///   - predictedEndTranslation: 相对手势起点的**总**投射位移。
    ///   - geometry: 页宽 + 当前页下标 + 总页数。
    public static func turn(
        trackedOffset: CGFloat,
        translation: CGFloat,
        predictedEndTranslation: CGFloat,
        geometry: PagePanGeometry
    ) -> PagePanTurn {
        let settled = settledOffset(
            trackedOffset: trackedOffset,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        guard crossesScreenMidline(offset: settled, availableWidth: geometry.availableWidth) else {
            return .none
        }
        if settled < 0 {
            return geometry.pageIndex + 1 < geometry.pageCount ? .next : .none
        }
        return geometry.pageIndex > 0 ? .previous : .none
    }
}
