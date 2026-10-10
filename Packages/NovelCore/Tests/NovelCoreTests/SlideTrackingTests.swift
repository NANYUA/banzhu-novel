import CoreGraphics
@testable import NovelCore
import XCTest

/// 滑动翻页「从当前显示位置继续跟手」（方案 A）的纯数学。
///
/// 手势与动画本身（`DragGesture` / `withAnimation`）在纯 Swift 包里测不了，
/// 但「抓取基线 + 本次位移 → 页面偏移」这段数学可以 —— 而它正是本次唯一改动的东西。
///
/// 最关键的是第一条：**基线为 0（没有动画在跑）时必须与改动前逐值一致**。
/// 为了让这条回归有牙齿，旧写法在下面被逐字抄了一遍当对照，且断言用**精确相等**。
final class SlideTrackingTests: XCTestCase {
    private let width: CGFloat = 390

    // MARK: - 回归：基线为 0 时逐值一致

    /// 改动前的写法（逐字抄自重构前的 `ReaderView.slideGesture`）。
    private func legacyOffset(
        translation: CGFloat,
        availableWidth: CGFloat,
        pageIndex: Int,
        pageCount: Int
    ) -> CGFloat {
        let raw = translation
        let edge = raw > 0 ? pageIndex <= 0 : pageIndex + 1 >= pageCount
        return edge ? raw * availableWidth * 0.55 / (availableWidth + 0.55 * abs(raw)) : raw
    }

    /// 没有动画在跑时（基线 0），新实现必须与旧实现**逐值相等**（不是近似）。
    func test基线为0时与改动前逐值一致() {
        let widths: [CGFloat] = [320, 390, 1024]
        let pageCases: [(index: Int, count: Int)] = [(0, 10), (1, 10), (5, 10), (9, 10), (0, 1)]
        let translations: [CGFloat] = [-400, -137.5, -60, -10, -0.5, 0, 0.5, 10, 60, 137.5, 400]

        for availableWidth in widths {
            for pageCase in pageCases {
                for translation in translations {
                    let expected = legacyOffset(
                        translation: translation,
                        availableWidth: availableWidth,
                        pageIndex: pageCase.index,
                        pageCount: pageCase.count
                    )
                    let actual = SlideTracking.offset(
                        fromDisplayedOffset: 0,
                        translation: translation,
                        availableWidth: availableWidth,
                        pageIndex: pageCase.index,
                        pageCount: pageCase.count
                    )
                    XCTAssertEqual(
                        actual,
                        expected,
                        "基线为 0 时行为必须不变：w=\(availableWidth) 第\(pageCase.index)/\(pageCase.count)页 t=\(translation)"
                    )
                }
            }
        }
    }

    // MARK: - 非边界：基线 + translation

    /// 动画中途再抓（非边界）：基线 35、本次位移 10 → 45，而不是从 0 重开的 10。
    func test非边界时等于基线加本次位移() {
        XCTAssertEqual(offset(from: 35, translation: 10), 45)
        XCTAssertEqual(offset(from: -35, translation: -10), -45)
        XCTAssertEqual(offset(from: 0, translation: 10), 10)
        // 可逆转：抓在 +35 上继续反向拖，能一路回到负向，不被夹在 0。
        XCTAssertEqual(offset(from: 35, translation: -50), -15)
    }

    // MARK: - 边界：橡皮筋

    /// 左边界（第 0 页向右拖）：单调递增、有界。
    ///
    /// 注意上限：旧公式 `x·W·0.55/(W+0.55|x|)` 的渐近线是 **W**（`0.55` 是起始阻力，
    /// 不是上限），这里不改它 —— 改了就是破坏已验收的边界手感。
    func test左边界橡皮筋单调且不超过一屏宽() {
        var previous: CGFloat = 0
        for translation in [1.0, 5.0, 20.0, 60.0, 150.0, 400.0, 1_000_000.0] as [CGFloat] {
            let value = offset(from: 0, translation: translation, index: 0, count: 10)
            XCTAssertGreaterThan(value, previous, "橡皮筋必须单调递增（t=\(translation)）")
            XCTAssertLessThan(value, width, "橡皮筋必须始终不到一屏宽（t=\(translation)）")
            previous = value
        }
        // 起始阻力仍是旧的 0.55：小位移下≈0.55:1
        XCTAssertEqual(offset(from: 0, translation: 1, index: 0, count: 10), 0.55, accuracy: 0.001)
    }

    /// 右边界（末页向左拖）：与左侧对称的单调、有界（负向）。
    func test右边界橡皮筋单调且不小于负一屏宽() {
        var previous: CGFloat = 0
        for translation in [-1.0, -5.0, -20.0, -60.0, -150.0, -400.0, -1_000_000.0] as [CGFloat] {
            let value = offset(from: 0, translation: translation, index: 9, count: 10)
            XCTAssertLessThan(value, previous, "橡皮筋必须单调递减（t=\(translation)）")
            XCTAssertGreaterThan(value, -width, "橡皮筋必须始终不到一屏宽（t=\(translation)）")
            previous = value
        }
        XCTAssertEqual(offset(from: 0, translation: -1, index: 9, count: 10), -0.55, accuracy: 0.001)
    }

    /// 只有一页时两个方向都是边界，两侧都必须有界（不能把画面拖到天边）。
    func test单页时两侧都走橡皮筋() {
        XCTAssertLessThan(offset(from: 0, translation: 400, index: 0, count: 1), width)
        XCTAssertGreaterThan(offset(from: 0, translation: -400, index: 0, count: 1), -width)
    }

    // MARK: - 边界上「动画没跑完就再抓」

    /// 边界抓取瞬间不能跳变：本次位移再小，结果也只能离开显示值一点点。
    ///
    /// 橡皮筋是 1-Lipschitz（斜率 = W²·r/(W+r|x|)² ≤ r < 1），
    /// 所以 `|结果 − 显示值| ≤ |本次位移|` 必须成立。
    func test边界上抓取瞬间不跳变() {
        let baselines: [CGFloat] = [8, 12, 24, 35, 48]
        let translations: [CGFloat] = [0.001, 0.05, 0.2, 1, 3]

        for baseline in baselines {
            for translation in translations {
                let value = offset(from: baseline, translation: translation, index: 0, count: 10)
                XCTAssertLessThanOrEqual(
                    abs(value - baseline),
                    translation,
                    "抓取瞬间的位移不得超过本次手势位移（基线 \(baseline)）"
                )
                XCTAssertGreaterThan(value, baseline, "方向必须仍然跟手（基线 \(baseline)）")
            }
        }
    }

    /// 边界上「抓取后继续拖」与「一直没松手」必须走同一条轨迹。
    ///
    /// 先把显示的 35pt 还原成它对应的未压缩位移，两者应当算出**同一个值**。
    func test边界抓取后与一直未松手同轨迹() throws {
        let displayed: CGFloat = 35
        let unsquashed = try XCTUnwrap(
            SlideTracking.unrestrainedOffset(of: displayed, availableWidth: width)
        )

        let grabbed = offset(from: displayed, translation: 30, index: 0, count: 10)
        let neverReleased = offset(from: 0, translation: unsquashed + 30, index: 0, count: 10)

        XCTAssertEqual(grabbed, neverReleased, accuracy: 1e-9)
        // 同一条轨迹也意味着：抓取瞬间（t→0）结果就是显示值本身。
        XCTAssertEqual(offset(from: displayed, translation: 0.0001, index: 0, count: 10), displayed, accuracy: 0.01)
    }

    /// 反函数确实是橡皮筋的逆：来回一趟应当回到原处。
    func test反函数还原未压缩位移() throws {
        for squashed in [-180.0, -60.0, -12.0, 0.0, 12.0, 60.0, 180.0] as [CGFloat] {
            let unsquashed = try XCTUnwrap(
                SlideTracking.unrestrainedOffset(of: squashed, availableWidth: width)
            )
            let roundTrip = SlideTracking.rubberBanded(unsquashed, availableWidth: width)
            XCTAssertEqual(roundTrip, squashed, accuracy: 1e-9)
        }
        // 0 是精确的不动点 —— 「基线为 0 逐值一致」这条回归就靠它。
        XCTAssertEqual(try XCTUnwrap(SlideTracking.unrestrainedOffset(of: 0, availableWidth: width)), 0)
    }

    /// 反函数在 `|y| → W`（奇点）处发散，必须显式挡住，而不是算出 `inf` / `nan`。
    ///
    /// 橡皮筋的值域是 `(-W, W)`，`|y| >= W` 的显示值根本压不出来；
    /// 真能碰到它的只有「动画途中容器宽度突然变小」。
    /// 两条子断言：值域内贴近饱和（`0.999W`）仍然不漏性质；值域外显式早退成 1:1。
    func test接近橡皮筋饱和值时不发散也不跳变() throws {
        // ① 值域内、贴着渐近线：还原得出来，且「不跳变 + 有界」都还在。
        let nearSaturation = width * 0.999
        let unsquashed = try XCTUnwrap(
            SlideTracking.unrestrainedOffset(of: nearSaturation, availableWidth: width)
        )
        XCTAssertFalse(unsquashed.isNaN)
        XCTAssertFalse(unsquashed.isInfinite)

        let value = offset(from: nearSaturation, translation: 0.001, index: 0, count: 10)
        XCTAssertEqual(value, nearSaturation, accuracy: 0.01, "贴着饱和值时抓取仍不得跳变")
        XCTAssertLessThan(value, width, "再贴饱和也必须严格小于一屏宽")

        // ② 值域外（含奇点本身）：早退为 nil，调用方退回 1:1 —— 不跳变、不出 inf/nan。
        XCTAssertNil(SlideTracking.unrestrainedOffset(of: width, availableWidth: width))
        XCTAssertNil(SlideTracking.unrestrainedOffset(of: width * 1.5, availableWidth: width))
        XCTAssertNil(SlideTracking.unrestrainedOffset(of: -width, availableWidth: width))
        let fallback = offset(from: width * 1.5, translation: 12, index: 0, count: 10)
        XCTAssertFalse(fallback.isNaN)
        XCTAssertEqual(fallback, width * 1.5 + 12, "取不到逆时就退回 1:1，至少不瞬移")
    }

    /// 退化盒子（宽 0）不得算出 NaN / 无穷 —— 真机上会直接把视图布局搞坏。
    func test零宽度时不产生NaN() {
        let value = offset(from: 12, translation: -12, width: 0, index: 0, count: 10)
        XCTAssertEqual(value, 0)
        XCTAssertFalse(value.isNaN)
    }

    // MARK: - 辅助

    private func offset(
        from displayed: CGFloat,
        translation: CGFloat,
        width availableWidth: CGFloat? = nil,
        index: Int = 5,
        count: Int = 10
    ) -> CGFloat {
        SlideTracking.offset(
            fromDisplayedOffset: displayed,
            translation: translation,
            availableWidth: availableWidth ?? width,
            pageIndex: index,
            pageCount: count
        )
    }
}
