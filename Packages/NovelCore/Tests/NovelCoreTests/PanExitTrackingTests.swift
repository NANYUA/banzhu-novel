import CoreGraphics
@testable import NovelCore
import XCTest

/// 测试用屏宽（与 `PagePanTrackingTests` / `PagePanChapterBoundaryTests` 同一个值）。
private let exitScreenWidth: CGFloat = 390

/// 「在全书第 1 页右滑直接退出本书」的判退纯数学。
///
/// 手势与 `dismiss()` 本身在 App 层测不了，但**判退的四条阈值**可以 —— 而阈值正是
/// 这一条需求里唯一会「写错就误退 / 退不掉」的东西。
///
/// 四条最有牙齿的用例：
/// - `test不是全书第一页时永远不判退`：够距离 + 够速度也**不退**（其它页的右滑是章间导航）；
/// - `test慢拖不够距离时不判退`：距离门与速度门**同时**不满足才不退；
/// - `test快甩位移足够时判退`：位移不够距离门，但速度够 ⇒ 仍然退；
/// - `test一帧之内的合成事件速度记零`：`dt < 8ms` 不被当成超快甩动。
final class PanExitTrackingTests: XCTestCase {
    // MARK: - 距离门

    /// 够距离（> 屏宽 × 0.35）⇒ 退，与速度无关。
    func test够距离时判退() {
        XCTAssertTrue(
            exits(translation: exitScreenWidth * 0.35 + 1),
            "位移超过屏宽 35% 必须判退（demo 04 口径）"
        )
        XCTAssertTrue(exits(translation: exitScreenWidth), "整屏右滑必须判退")
    }

    /// 正好卡在距离门上 ⇒ **不退**（口径是「超过」）。
    func test正好卡在距离门上不判退() {
        XCTAssertFalse(
            exits(translation: exitScreenWidth * 0.35),
            "口径是「> 屏宽 × 0.35」，正好等于不算够"
        )
    }

    /// 慢拖且不够距离 ⇒ 不退（距离门与速度门同时不满足）。
    func test慢拖不够距离时不判退() {
        // 130pt / 1.3s = 0.1 pt/ms，远低于 0.5 的速度门；130 < 390 × 0.35 = 136.5。
        let slow = [sample(0, at: 0), sample(65, at: 0.65), sample(130, at: 1.3)]
        XCTAssertFalse(
            exits(translation: 130, samples: slow),
            "慢拖不够距离必须回弹，不能退出本书"
        )
    }

    // MARK: - 速度门

    /// 快甩 + 位移过了速度门的 12% 下限 ⇒ 退（虽然不够距离门）。
    func test快甩位移足够时判退() {
        // 120pt / 90ms ≈ 1.33 pt/ms（> 0.5）；120 > 390 × 0.12 = 46.8，但 < 136.5。
        let flick = [sample(0, at: 0), sample(60, at: 0.045), sample(120, at: 0.09)]
        XCTAssertTrue(exits(translation: 120, samples: flick), "够快的右甩必须判退")
    }

    /// 快但位移太小（不够屏宽 12%）⇒ 不退 —— 挡住轻微快速抖动。
    func test快但位移太小时不判退() {
        // 同样约 1.33 pt/ms，但只有 30pt（< 46.8）。
        let jitter = [sample(0, at: 0), sample(15, at: 0.01125), sample(30, at: 0.0225)]
        XCTAssertFalse(exits(translation: 30, samples: jitter), "位移太小的快抖不能退出本书")
    }

    /// 采样窗口只取最近约 90ms：手势中途快、抬手前停住 ⇒ 抬手速度按停住那段算。
    func test速度只看最近九十毫秒() {
        // 前 200ms 快（300pt/200ms = 1.5 pt/ms），随后 200ms 停住（0 pt/ms）。
        let samples = [
            sample(0, at: 0),
            sample(300, at: 0.2),
            sample(300, at: 0.4),
        ]
        // 位移取 130（< 136.5，过 12% 下限）⇒ 只能靠速度门，而窗口内速度是 0。
        XCTAssertFalse(
            exits(translation: 130, samples: samples),
            "抬手前停住的手势必须按停住那段算速度"
        )
        XCTAssertEqual(velocity(samples), 0, "最近 90ms 内没有位移，速度必须是 0")
    }

    /// `dt < 8ms` ⇒ 速度记 0（一帧内挤进来的合成事件不能当成超快甩动）。
    func test一帧之内的合成事件速度记零() {
        let synthetic = [sample(0, at: 0), sample(200, at: 0.004)]
        XCTAssertEqual(velocity(synthetic), 0, "dt < 8ms 时速度必须记 0")
        XCTAssertFalse(
            exits(translation: 130, samples: synthetic),
            "合成事件不能靠假速度判退"
        )
    }

    /// 采样不足（0 / 1 个点）⇒ 速度 0，只剩距离门说了算。
    func test采样不足时速度为零() {
        XCTAssertEqual(velocity([]), 0)
        XCTAssertEqual(velocity([sample(0, at: 0)]), 0)
        XCTAssertFalse(exits(translation: 130, samples: []), "没有速度采样时不能靠速度判退")
    }

    /// 速度有符号（正 = 向右），判退时取绝对值 —— 方向由调用点把关。
    func test速度有符号而判退取绝对值() {
        let rightward = [sample(0, at: 0), sample(60, at: 0.045), sample(120, at: 0.09)]
        let leftward = [sample(0, at: 0), sample(-60, at: 0.045), sample(-120, at: 0.09)]
        XCTAssertGreaterThan(velocity(rightward), 0, "向右为正")
        XCTAssertLessThan(velocity(leftward), 0, "向左为负")
        XCTAssertEqual(velocity(rightward), -velocity(leftward), "两个方向的速度必须只差符号")
        XCTAssertTrue(exits(translation: 120, samples: leftward), "判退只看速度大小，方向由调用点把关")
    }

    // MARK: - 全书第 1 页

    /// 不是全书第 1 页 ⇒ **永远不退**，够距离 + 够速度也不退。
    func test不是全书第一页时永远不判退() {
        let flick = [sample(0, at: 0), sample(60, at: 0.045), sample(120, at: 0.09)]
        XCTAssertFalse(
            exits(translation: exitScreenWidth, samples: flick, isBookFirstPage: false),
            "整屏右滑也不能退（其它页的右滑是章间导航）"
        )
        XCTAssertFalse(
            exits(translation: 120, samples: flick, isBookFirstPage: false),
            "快甩也不能退"
        )
        XCTAssertFalse(
            exits(translation: 0, samples: [], isBookFirstPage: false),
            "没有位移时更不能退"
        )
    }

    /// 全书第 1 页 + 没滑动 ⇒ 不退（只点一下不能退出本书）。
    func test全书第一页没有位移时不判退() {
        XCTAssertFalse(exits(translation: 0, samples: []), "零位移不能退出本书")
        XCTAssertFalse(
            exits(translation: 0, samples: [sample(0, at: 0), sample(0, at: 0.09)]),
            "零位移的快事件也不能退出本书"
        )
    }

    // MARK: - 退化盒子

    /// 屏宽为 0（退化盒子）：距离门的阈值也退化成 0 ⇒ **任何正位移**都过距离门，
    /// 速度门在这个盒子里无法被单独观察到（`distance > 0` 恒强于 `distance > 0.12 × 0`）。
    /// 记在这里只为锁住退化输入的现状；生产路径另有 `translation.width > 0` 前置
    /// （`endSlide` 里的 `shouldExitBook`），左滑根本不会走到判退。
    func test屏宽为零时距离门阈值退化成零() {
        let flick = [sample(0, at: 0), sample(60, at: 0.045), sample(120, at: 0.09)]
        XCTAssertFalse(
            exits(translation: 0, availableWidth: 0, samples: []),
            "零位移 ⇒ 距离门（0 > 0）与 12% 下限都不成立 ⇒ 不退"
        )
        XCTAssertTrue(
            exits(translation: 1000, availableWidth: 0, samples: []),
            "屏宽 0 ⇒ 阈值 0 ⇒ 任何正位移都过距离门（退化结果，非设计意图）"
        )
        XCTAssertTrue(
            exits(translation: 120, availableWidth: 0, samples: flick),
            "屏宽 0 时快甩也判退 —— 走的仍是距离门，速度门在这里观察不到"
        )
    }
}

// MARK: - 夹具（文件级：放类里只会把 `type_body_length` 顶到 250 的门槛上）

/// 判退的默认上下文：整屏宽 + 全书第 1 页 + 空采样（即只靠距离门）。
private func exits(
    translation: CGFloat,
    availableWidth: CGFloat = exitScreenWidth,
    samples: [PanExitSample] = [],
    isBookFirstPage: Bool = true
) -> Bool {
    PanExitTracking.exitsBook(
        translation: translation,
        availableWidth: availableWidth,
        samples: samples,
        isBookFirstPage: isBookFirstPage
    )
}

private func velocity(_ samples: [PanExitSample]) -> CGFloat {
    PanExitTracking.velocity(samples: samples)
}

private func sample(_ translation: CGFloat, at timestamp: TimeInterval) -> PanExitSample {
    PanExitSample(translation: translation, timestamp: timestamp)
}
