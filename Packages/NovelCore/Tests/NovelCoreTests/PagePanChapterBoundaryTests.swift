import CoreGraphics
@testable import NovelCore
import XCTest

/// 平移翻页在**章尾 / 章首**的跟手：相邻章已就绪就不阻尼（owner 报的手感差异）。
///
/// ## 为什么要改
/// 跟手量原来只看「当前页是不是本章首 / 末页」定边界：章尾一律走橡皮筋 ⇒ 跨章时最多
/// 只能把两页的书脊拉到屏幕中线；章内任意两页之间 1:1 跟手 ⇒ 能整页拉过去。
/// 现在章尾 / 章首**还要看相邻章那一格有没有内容**（`panSlots` 渲染 `+1` / `-1` 格的
/// 判据：`nextPages` / `previousPages` 非空）：有 ⇒ 与章内同一条路；没有 ⇒ 保留橡皮筋。
///
/// 判页口径（`PagePanTracking.turn` 的中线判据）**没有动** —— 这一组用例的最后一条
/// 专门钉住「跟手变宽松了，但翻页门槛还是中线」。
///
/// 单独一个文件：`PagePanTrackingTests` 的类体已越过 `type_body_length` 的 250 行，
/// 而这一组是**另一条口径**（章边界），不与该文件的「单页约束 / 中线判据」混在一起。
final class PagePanChapterBoundaryTests: XCTestCase {
    /// 测试用页宽（一页 = 一屏可用宽）。
    private let pageWidth: CGFloat = 390

    // MARK: - 相邻章可用 ⇒ 不阻尼，整页拉得过去

    /// 章尾 + 下一章第 1 页已就绪 ⇒ **不阻尼**，能整页拉过去（`-pageWidth`）。
    func test章尾下一章就绪时整页跟手() {
        for translation in [-1.0, -60.0, -pageWidth / 2, -pageWidth, -400.0] as [CGFloat] {
            XCTAssertEqual(
                offset(translation: translation, index: 9, count: 10, hasNext: true),
                translation,
                "章尾 + 下一章就绪必须 1:1 跟手（t=\(translation)）"
            )
        }
        // 「整页拉过去」= 正好一页宽：与章内任意两页之间同一个落点。
        XCTAssertEqual(offset(translation: -pageWidth, index: 9, count: 10, hasNext: true), -pageWidth)
        XCTAssertEqual(
            offset(translation: -pageWidth, index: 9, count: 10, hasNext: true),
            offset(translation: -pageWidth, index: 3, count: 10, hasNext: true),
            "章尾与章内必须落到同一个偏移"
        )
    }

    /// 章首 + 上一章最后一页已就绪 ⇒ 同样整页跟手（与章尾镜像）。
    func test章首上一章就绪时整页跟手() {
        for translation in [1.0, 60.0, pageWidth / 2, pageWidth, 400.0] as [CGFloat] {
            XCTAssertEqual(
                offset(translation: translation, index: 0, count: 10, hasPrevious: true),
                translation,
                "章首 + 上一章就绪必须 1:1 跟手（t=\(translation)）"
            )
        }
    }

    // MARK: - 相邻章不可用 ⇒ 仍阻尼（回归保护）

    /// 相邻章**不可用**（最后一章 / 还没预加载完）⇒ 仍走已验收的橡皮筋。
    func test相邻章不可用时仍走橡皮筋() {
        var previous: CGFloat = 0
        for translation in [-1.0, -5.0, -20.0, -60.0, -150.0, -400.0, -1_000_000.0] as [CGFloat] {
            let value = offset(translation: translation, index: 9, count: 10)
            XCTAssertLessThan(value, previous, "相邻章不可用时仍必须单调递减（t=\(translation)）")
            XCTAssertGreaterThan(value, -pageWidth, "相邻章不可用时必须始终不到一屏宽（t=\(translation)）")
            previous = value
        }
        XCTAssertEqual(offset(translation: -1, index: 9, count: 10), -0.55, accuracy: 0.001)
        // 章首右滑：镜像。
        XCTAssertLessThan(offset(translation: 400, index: 0, count: 10), pageWidth)
        XCTAssertEqual(offset(translation: 1, index: 0, count: 10), 0.55, accuracy: 0.001)
    }

    // MARK: - 只放宽有相邻章的那一侧 / 章内逐值不变

    /// 只放宽有相邻章的那一侧，另一侧照旧阻尼。
    func test只有一侧有相邻章时只放宽那一侧() {
        XCTAssertEqual(
            offset(translation: -pageWidth, index: 9, count: 10, hasNext: true),
            -pageWidth,
            "下一章就绪：向前整页"
        )
        XCTAssertLessThan(
            offset(translation: pageWidth, index: 0, count: 10, hasNext: true),
            pageWidth,
            "上一章没就绪：向后仍是橡皮筋"
        )
    }

    /// 相邻章就绪只放宽**章尾 / 章首**这两个边界，章内一字不动。
    func test相邻章就绪不影响章内跟手() {
        for translation in [-pageWidth, -137.5, -10.0, 0.0, 10.0, 137.5, pageWidth] as [CGFloat] {
            for index in [1, 5, 8] {
                XCTAssertEqual(
                    offset(translation: translation, index: index, count: 10, hasNext: true, hasPrevious: true),
                    translation,
                    "章内仍必须 1:1（第\(index)页 t=\(translation)）"
                )
            }
        }
    }

    // MARK: - 判页口径没动

    /// 跟手放宽的那一侧，判页仍然是同一条口径（中线 + 相邻章就绪 ⇒ `.next`）。
    func test章尾整页跟手后判页仍走中线判据() {
        let geometry = PagePanGeometry(
            availableWidth: pageWidth,
            pageIndex: 9,
            pageCount: 10,
            hasNextChapterPage: true
        )
        let tracked = PagePanTracking.panOffset(
            fromDisplayedOffset: 0,
            translation: -pageWidth,
            geometry: geometry
        )
        XCTAssertEqual(tracked, -pageWidth)
        // 中线越过 + 下一章就绪 ⇒ `.next`（换章由调用方落位），与章内翻页同一个判据。
        XCTAssertEqual(
            PagePanTracking.turn(
                trackedOffset: tracked,
                translation: -pageWidth,
                predictedEndTranslation: -pageWidth,
                geometry: geometry
            ),
            .next
        )
        // 只拖到中线之前 ⇒ 仍滑回本页（跟手变宽松没有动判页门槛）。
        XCTAssertEqual(
            PagePanTracking.turn(
                trackedOffset: -pageWidth * 0.4,
                translation: -pageWidth * 0.4,
                predictedEndTranslation: -pageWidth * 0.4,
                geometry: geometry
            ),
            .none
        )
    }
}

// MARK: - 夹具（文件级纯函数，不占 `type_body_length`）

/// 章尾 / 章首的跟手位移：几何里带上「相邻章是否已就绪」。
///
/// 五个形参正是 `function_parameter_count` 的 warning 档上限，不能再加
/// （页宽固定用 390）。
private func offset(
    translation: CGFloat,
    index: Int,
    count: Int,
    hasNext: Bool = false,
    hasPrevious: Bool = false
) -> CGFloat {
    PagePanTracking.panOffset(
        fromDisplayedOffset: 0,
        translation: translation,
        geometry: PagePanGeometry(
            availableWidth: 390,
            pageIndex: index,
            pageCount: count,
            hasNextChapterPage: hasNext,
            hasPreviousChapterPage: hasPrevious
        )
    )
}
