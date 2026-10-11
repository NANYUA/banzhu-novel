import CoreGraphics
@testable import NovelCore
import XCTest

/// 章尾 / 章首的跟手边界：**相邻章已就绪就不算边界**（owner 报的手感差异）。
///
/// ## 为什么要改
/// `SlideTracking.offset` 的边界判据原来只看「当前页是不是本章首 / 末页」：
/// 章尾（`pageIndex + 1 >= pageCount`）一律走橡皮筋 ⇒ 跨章时最多只能把两页的书脊
/// 拉到屏幕中线；而章内任意两页之间 1:1 跟手 ⇒ 能整页拉过去。两条路的差别只有这一处。
///
/// 现在章尾 / 章首**还要看相邻章那一格有没有内容**（`panSlots` 渲染 `+1` / `-1` 格的
/// 判据：`nextPages` / `previousPages` 非空）：有 ⇒ 与章内同一条路（不阻尼）；
/// 没有（最后一章 / 还没预加载完）⇒ 保留橡皮筋，不把空白拉出来。
///
/// 单独一个文件：`SlideTrackingTests` 已贴近 `file_length` / `type_body_length`，
/// 而这组用例是**另一条口径**（章边界），不与「一页怎么跟手」混在一起。
final class SlideChapterBoundaryTests: XCTestCase {
    private let width: CGFloat = 390

    // MARK: - 相邻章可用 ⇒ 不阻尼

    /// 章尾 + 下一章第 1 页已就绪 ⇒ **不阻尼**：跟手与章内翻页逐值相同（整页拉得过去）。
    func test章尾下一章就绪时整页跟手不阻尼() {
        let translations: [CGFloat] = [-1, -60, -137.5, -width, -400]
        for translation in translations {
            XCTAssertEqual(
                offset(translation: translation, index: 9, count: 10, hasNext: true),
                translation,
                "章尾 + 下一章就绪必须 1:1 跟手（t=\(translation)）"
            )
        }
        // 「整页拉过去」这条就是 `-availableWidth` 本身：与章内任意两页之间同一个落点。
        XCTAssertEqual(offset(translation: -width, index: 9, count: 10, hasNext: true), -width)
        XCTAssertEqual(
            offset(translation: -width, index: 9, count: 10, hasNext: true),
            offset(translation: -width, index: 3, count: 10, hasNext: true),
            "章尾与章内必须落到同一个偏移"
        )
    }

    /// 章首 + 上一章最后一页已就绪 ⇒ 同样**不阻尼**（与章尾镜像）。
    func test章首上一章就绪时整页跟手不阻尼() {
        for translation in [1.0, 60.0, 137.5, width, 400.0] as [CGFloat] {
            XCTAssertEqual(
                offset(translation: translation, index: 0, count: 10, hasPrevious: true),
                translation,
                "章首 + 上一章就绪必须 1:1 跟手（t=\(translation)）"
            )
        }
        XCTAssertEqual(offset(translation: width, index: 0, count: 10, hasPrevious: true), width)
    }

    // MARK: - 相邻章不可用 ⇒ 仍阻尼（回归保护）

    /// 相邻章**不可用**（最后一章 / 还没预加载完）⇒ 仍走已验收的橡皮筋。
    ///
    /// 这一格是空的（`panSlots` 不铺），去掉阻尼就会把空白拉出来 —— 所以必须保留。
    func test相邻章不可用时仍走橡皮筋() {
        // 章尾左滑：单调递减且有界（永远到不了 -width）。
        var previous: CGFloat = 0
        for translation in [-1.0, -5.0, -20.0, -60.0, -150.0, -400.0, -1_000_000.0] as [CGFloat] {
            let value = offset(translation: translation, index: 9, count: 10)
            XCTAssertLessThan(value, previous, "相邻章不可用时仍必须单调递减（t=\(translation)）")
            XCTAssertGreaterThan(value, -width, "相邻章不可用时必须始终不到一屏宽（t=\(translation)）")
            previous = value
        }
        XCTAssertEqual(offset(translation: -1, index: 9, count: 10), -0.55, accuracy: 0.001)
        // 章首右滑：镜像。
        XCTAssertLessThan(offset(translation: 400, index: 0, count: 10), width)
        XCTAssertEqual(offset(translation: 1, index: 0, count: 10), 0.55, accuracy: 0.001)
    }

    // MARK: - 只放宽有相邻章的那一侧

    /// 两个方向各看各的相邻章：只放宽有内容的那一侧，另一侧照旧阻尼。
    func test只有一侧有相邻章时只放宽那一侧() {
        XCTAssertEqual(
            offset(translation: -width, index: 9, count: 10, hasNext: true),
            -width,
            "下一章就绪：向前整页"
        )
        XCTAssertLessThan(
            offset(translation: width, index: 0, count: 10, hasNext: true),
            width,
            "上一章没就绪：向后仍是橡皮筋"
        )
    }

    // MARK: - 章内逐值不变（回归保护）

    /// 相邻章就绪只放宽**章尾 / 章首**这两个边界，章内行为一字不动。
    func test相邻章就绪不影响章内() {
        for translation in [-width, -137.5, -10.0, 0.0, 10.0, 137.5, width] as [CGFloat] {
            for index in [1, 5, 8] {
                XCTAssertEqual(
                    offset(translation: translation, index: index, count: 10, hasNext: true, hasPrevious: true),
                    translation,
                    "章内仍必须 1:1（第\(index)页 t=\(translation)）"
                )
            }
        }
    }
}

// MARK: - 夹具（文件级纯函数，不占 `type_body_length`）

/// 基线 0 的跟手位移：`hasNext` / `hasPrevious` 默认 `false`（改动前「章尾 / 章首
/// 一律算边界」的旧语义）。
///
/// 五个形参正是 `function_parameter_count` 的 warning 档上限，不能再加
/// （页宽固定用类里的 `width`）。
private func offset(
    translation: CGFloat,
    index: Int,
    count: Int,
    hasNext: Bool = false,
    hasPrevious: Bool = false
) -> CGFloat {
    SlideTracking.offset(
        fromDisplayedOffset: 0,
        translation: translation,
        availableWidth: 390,
        position: SlideTracking.PagePosition(index: index, count: count),
        neighbors: SlideTracking.ChapterNeighbors(hasNext: hasNext, hasPrevious: hasPrevious)
    )
}
