import CoreGraphics
@testable import NovelCore
import XCTest

/// 测试用页宽（一页 = 一屏可用宽）。
private let pageWidth: CGFloat = 390

/// 平移翻页（全景图式左右平移）的纯数学。
///
/// 手势与动画本身（`DragGesture` / `withAnimation`）在纯 Swift 包里测不了，
/// 但「单页约束」与「中线判据」这两条**本次新增的规则**可以 —— 而它们正是本次唯一改动的东西。
///
/// 两条最有牙齿的用例：
/// - `test基线为0时判页与U0-8旧规则逐值一致`：把 U0-8 已验收的动量判向**逐字抄进测试**当对照；
/// - `test中线判据与两页共享边写法等价`：把「两页中线越过屏幕中线」的几何写法与化简式钉在一起。
///
/// 夹具（`panOffset` / `turnAtSettledOffset` / `legacyTurn`）刻意放在**文件级**：
/// 它们是纯函数，放类里只会把 `type_body_length` 顶到 250 的门槛上。
final class PagePanTrackingTests: XCTestCase {
    // MARK: - 单页约束

    /// 一次最多一页：非边界方向拖多远，跟手位移都夹在一页宽内。
    func test单页约束把跟手位移夹在一页内() {
        let translations: [CGFloat] = [100, 390, 391, 600, 5000]
        for translation in translations {
            let value = panOffset(translation: translation, index: 5, count: 10)
            XCTAssertLessThanOrEqual(value, pageWidth, "向左最多一页（t=\(translation)）")
            XCTAssertGreaterThan(value, 0, "方向仍是跟手（t=\(translation)）")
        }
        for translation in translations.map({ -$0 }) {
            let value = panOffset(translation: translation, index: 5, count: 10)
            XCTAssertGreaterThanOrEqual(value, -pageWidth, "向右最多一页（t=\(translation)）")
            XCTAssertLessThan(value, 0, "方向仍是跟手（t=\(translation)）")
        }
        // 夹的是「一页」这个上界本身，不是比它更小的数：拖过一页就正好停在一页处。
        XCTAssertEqual(panOffset(translation: 600, index: 5, count: 10), pageWidth)
    }

    /// 非边界、基线为 0 时，跟手就是 1:1 —— 一页之内逐值等于本次位移。
    func test非边界基线为0时一页内与位移逐值一致() {
        for translation in [-380.0, -200.0, -10.0, 0.0, 10.0, 200.0, 380.0] as [CGFloat] {
            XCTAssertEqual(panOffset(translation: translation, index: 5, count: 10), translation)
        }
    }

    /// 文档首尾那一支必须**逐值等于** `SlideTracking` 的橡皮筋结果：边界手感是已验收行为。
    func test文档首尾仍走已验收的橡皮筋() {
        let translations: [CGFloat] = [1, 20, 200, 5000, 1_000_000]
        for translation in translations {
            XCTAssertEqual(
                panOffset(translation: translation, index: 0, count: 10),
                SlideTracking.offset(
                    fromDisplayedOffset: 0,
                    translation: translation,
                    availableWidth: pageWidth,
                    pageIndex: 0,
                    pageCount: 10
                ),
                "首页向右拖仍是橡皮筋（t=\(translation)）"
            )
        }
        for translation in translations.map({ -$0 }) {
            XCTAssertEqual(
                panOffset(translation: translation, index: 9, count: 10),
                SlideTracking.offset(
                    fromDisplayedOffset: 0,
                    translation: translation,
                    availableWidth: pageWidth,
                    pageIndex: 9,
                    pageCount: 10
                ),
                "末页向左拖仍是橡皮筋（t=\(translation)）"
            )
        }
        // 单页时两侧都是边界：两侧都必须有界（不能把画面拖到天边）。
        XCTAssertLessThan(panOffset(translation: 5000, index: 0, count: 1), pageWidth)
        XCTAssertGreaterThan(panOffset(translation: -5000, index: 0, count: 1), -pageWidth)
    }

    /// 动画中途再抓（非边界）：基线 35、本次位移 10 → 45（而不是从 0 重开的 10）。
    func test非边界基线加位移且仍受单页约束() {
        XCTAssertEqual(panOffset(from: 35, translation: 10), 45)
        XCTAssertEqual(panOffset(from: 35, translation: -50), -15)
        // 基线 + 位移一起越过一页，仍夹在一页内。
        XCTAssertEqual(panOffset(from: 300, translation: 300), pageWidth)
    }

    // MARK: - 中线判据

    /// 「两页中线越过屏幕中线」的几何写法与化简式 `|d| > W/2` 必须等价。
    ///
    /// 几何写法（当前页偏移 `d`、页宽 `W`）：
    /// - 向左拖：两页共享边在 `d + W`，越过屏幕中线 ⟺ `d + W < W/2`；
    /// - 向右拖：两页共享边在 `d`，越过 ⟺ `d > W/2`。
    func test中线判据与两页共享边写法等价() {
        let offsets: [CGFloat] = [
            -pageWidth, -pageWidth * 0.75, -pageWidth * 0.5 - 0.001, -pageWidth * 0.5,
            -pageWidth * 0.5 + 0.001, -1, 0, 1,
            pageWidth * 0.5 - 0.001, pageWidth * 0.5, pageWidth * 0.5 + 0.001,
            pageWidth * 0.75, pageWidth,
        ]
        for offset in offsets {
            let sharedEdgeCrossed = offset < 0
                ? (offset + pageWidth < pageWidth / 2)
                : (offset > pageWidth / 2)
            XCTAssertEqual(
                PagePanTracking.crossesScreenMidline(offset: offset, availableWidth: pageWidth),
                sharedEdgeCrossed,
                "中线判据必须与「两页共享边越过屏幕中线」等价（d=\(offset)）"
            )
        }
    }

    /// 中线**未**越过 → 滑回本页（`.none`）。
    func test中线未越过则滑回本页() {
        for offset in [-pageWidth * 0.5, -1.0, 0.0, 1.0, pageWidth * 0.5] as [CGFloat] {
            XCTAssertEqual(
                turnAtSettledOffset(offset, index: 5, count: 10),
                .none,
                "中线未越过屏幕中线必须滑回本页（d=\(offset)）"
            )
        }
    }

    /// 中线越过 → 翻一页，方向由落点符号决定。
    func test中线越过则按方向翻一页() {
        XCTAssertEqual(turnAtSettledOffset(-pageWidth * 0.5 - 0.001, index: 5, count: 10), .next)
        XCTAssertEqual(turnAtSettledOffset(-pageWidth, index: 5, count: 10), .next)
        XCTAssertEqual(turnAtSettledOffset(pageWidth * 0.5 + 0.001, index: 5, count: 10), .previous)
        XCTAssertEqual(turnAtSettledOffset(pageWidth, index: 5, count: 10), .previous)
    }

    // MARK: - 动量投射

    /// 动量只叠加**剩余**那段：`predictedEndTranslation` 是相对手势起点的总位移。
    func test动量投射只叠加剩余那段() {
        // 已经跟手走了 10，总投射 60 ⇒ 还剩 50 段动量 ⇒ 落点 35 + 50 = 85。
        XCTAssertEqual(
            PagePanTracking.settledOffset(trackedOffset: 35, translation: 10, predictedEndTranslation: 60),
            85
        )
        // 基线为 0（tracked == translation）时化简为总投射本身。
        XCTAssertEqual(
            PagePanTracking.settledOffset(trackedOffset: 10, translation: 10, predictedEndTranslation: 60),
            60
        )
        XCTAssertEqual(
            PagePanTracking.settledOffset(trackedOffset: 0, translation: 0, predictedEndTranslation: 0),
            0
        )
    }

    /// 快甩：跟手只走了 20pt，但动量投射把落点推过中线 → 仍然翻页（U0-8 的动量判向保留）。
    func test快甩时动量把落点推过中线仍翻页() {
        XCTAssertEqual(
            PagePanTracking.turn(
                trackedOffset: -20,
                translation: -20,
                predictedEndTranslation: -260,
                geometry: PagePanGeometry(availableWidth: pageWidth, pageIndex: 5, pageCount: 10)
            ),
            .next
        )
    }

    /// 慢拖过半页且没有动量 → 翻页；只拖到中线前一点点 → 滑回。
    func test慢拖以中线为界() {
        let half = pageWidth / 2
        XCTAssertEqual(turnAtSettledOffset(-(half - 1), index: 5, count: 10), .none)
        XCTAssertEqual(turnAtSettledOffset(-(half + 1), index: 5, count: 10), .next)
    }

    // MARK: - 回归：基线为 0 时与 U0-8 逐值一致

    /// 旧写法（逐字抄自 `ReaderView.slideGesture` 的 `onEnded`）：
    /// `let target = pageIndex + (projected < 0 ? 1 : -1)`
    /// `if abs(projected) > availableWidth / 2, pages.indices.contains(target) { … }`
    func test基线为0时判页与旧动量规则逐值一致() {
        let widths: [CGFloat] = [320, 390, 1024]
        let pageCases: [(index: Int, count: Int)] = [(0, 10), (1, 10), (5, 10), (9, 10), (0, 1)]
        let projected: [CGFloat] = [-400, -195, -60, -10, 0, 10, 60, 195, 400]

        for availableWidth in widths {
            for pageCase in pageCases {
                for value in projected {
                    let expected = legacyTurn(
                        predictedEndTranslation: value,
                        availableWidth: availableWidth,
                        pageIndex: pageCase.index,
                        pageCount: pageCase.count
                    )
                    // 基线 0 + 非边界：tracked == translation，落点化简为 projected。
                    let translation = min(max(value, -availableWidth), availableWidth)
                    let actual = PagePanTracking.turn(
                        trackedOffset: translation,
                        translation: translation,
                        predictedEndTranslation: value,
                        geometry: PagePanGeometry(
                            availableWidth: availableWidth,
                            pageIndex: pageCase.index,
                            pageCount: pageCase.count
                        )
                    )
                    XCTAssertEqual(
                        actual,
                        expected,
                        "基线 0 时判页必须与 U0-8 一致：w=\(availableWidth) 第\(pageCase.index)/\(pageCase.count)页 p=\(value)"
                    )
                }
            }
        }
    }

    // MARK: - 边界

    /// 首 / 末页：中线越过了也没有下一页 / 上一页 ⇒ 原地滑回，不越界。
    func test首末页不越界翻页() {
        XCTAssertEqual(turnAtSettledOffset(pageWidth, index: 0, count: 10), .none, "首页没有上一页")
        XCTAssertEqual(turnAtSettledOffset(-pageWidth, index: 9, count: 10), .none, "末页没有下一页")
        XCTAssertEqual(turnAtSettledOffset(-pageWidth, index: 0, count: 1), .none, "单页两边都没有")
    }

    /// 一次手势最多翻一页：拖过三页也只是 `.next`，不会跳页。
    func test一次手势最多翻一页() {
        let value = PagePanTracking.turn(
            trackedOffset: panOffset(translation: -pageWidth * 3, index: 5, count: 10),
            translation: -pageWidth * 3,
            predictedEndTranslation: -pageWidth * 4,
            geometry: PagePanGeometry(availableWidth: pageWidth, pageIndex: 5, pageCount: 10)
        )
        XCTAssertEqual(value, .next)
    }

    /// 退化盒子（宽 0）不得算出 NaN / 无穷，也不得判成翻页。
    func test零宽度不产生NaN() {
        let offset = panOffset(from: 12, translation: -12, width: 0, index: 5, count: 10)
        XCTAssertEqual(offset, 0)
        XCTAssertFalse(offset.isNaN)
        XCTAssertEqual(turnAtSettledOffset(0, width: 0, index: 5, count: 10), .none)
        XCTAssertFalse(PagePanTracking.crossesScreenMidline(offset: 100, availableWidth: 0))
    }
}

// MARK: - 夹具（文件级纯函数，不占 `type_body_length`）

/// 跟手位移（默认基线 0、页宽 `pageWidth`）。
private func panOffset(
    from displayed: CGFloat = 0,
    translation: CGFloat,
    width availableWidth: CGFloat? = nil,
    index: Int = 5,
    count: Int = 10
) -> CGFloat {
    PagePanTracking.panOffset(
        fromDisplayedOffset: displayed,
        translation: translation,
        availableWidth: availableWidth ?? pageWidth,
        pageIndex: index,
        pageCount: count
    )
}

/// 用「落点」直接问判页结果（跳过动量合成，专测中线那一步）。
private func turnAtSettledOffset(
    _ offset: CGFloat,
    width availableWidth: CGFloat? = nil,
    index: Int,
    count: Int
) -> PagePanTurn {
    PagePanTracking.turn(
        trackedOffset: offset,
        translation: 0,
        predictedEndTranslation: 0,
        geometry: PagePanGeometry(
            availableWidth: availableWidth ?? pageWidth,
            pageIndex: index,
            pageCount: count
        )
    )
}

/// U0-8 的旧判向（逐字抄自改动前的 `ReaderView.slideGesture.onEnded`）。
private func legacyTurn(
    predictedEndTranslation: CGFloat,
    availableWidth: CGFloat,
    pageIndex: Int,
    pageCount: Int
) -> PagePanTurn {
    let target = pageIndex + (predictedEndTranslation < 0 ? 1 : -1)
    guard abs(predictedEndTranslation) > availableWidth / 2,
          target >= 0, target < pageCount
    else {
        return .none
    }
    return predictedEndTranslation < 0 ? .next : .previous
}
