import CoreGraphics

/// 手势采样点：一次 `onChanged` 的「手指横坐标 + 时间戳」。
///
/// 时间戳由调用方给（`Date` / `CACurrentMediaTime` 都行，只要**同一次手势内同一个时钟**
/// 且单调不减）。本类型不认识时钟，只按 `timestamp` 的先后算速度 —— 纯数学，CI 可测。
public struct PanExitSample: Equatable, Sendable {
    /// 手指的横坐标（本次手势的 `DragGesture.Value.translation.width`）。
    public var translation: CGFloat
    /// 采样时刻（秒）。
    public var timestamp: TimeInterval

    public init(translation: CGFloat, timestamp: TimeInterval) {
        self.translation = translation
        self.timestamp = timestamp
    }
}

/// 「在全书第 1 页右滑直接退出本书」的判退纯数学，CI 可测。
///
/// ## 口径出处
/// 四条阈值**逐值照抄 owner 已确认通过的 demo 04**，不是本文件自己调的：
/// - 距离门 `|位移| > 屏宽 × 0.35`；
/// - 速度门 `速度 > 0.5 pt/ms`，采样窗口取**最近约 90ms**；
/// - 速度门另要求位移 `> 屏宽 × 0.12`（挡住轻微快速抖动）；
/// - `dt < 8ms` 时速度记 `0` —— 一帧内挤进来的合成事件会被当成「超快甩动」。
///
/// 满足**距离**或（**速度 + 速度门的位移**）任一 ⇒ 判退。
///
/// ## 为什么单独抽出来
/// 与 `PagePanTracking` 同一个理由：判退原来（以及如果不抽出来就会）活在 View 的
/// 手势闭包与 `@State` 之间，全仓零测试 —— 阈值写错只有真机手感能发现。抽成纯函数后，
/// 「够距离才退」「不够距离的快甩不误退」「不是全书第一页永远不退」这三条由 CI 兜住。
///
/// ## 只判「退不退」，不判「怎么退」
/// 退出动作本身（`dismiss()` 与系统返回动画）在 App 层，本类型不 import SwiftUI / UIKit
/// —— `scripts/check-architecture.sh` 规则 1 禁止 `Packages/` 引用 UI 框架。
public enum PanExitTracking {
    /// 距离门：位移绝对值超过屏宽的 35% ⇒ 判退（demo 04 口径）。
    public static let exitDistanceRatio: CGFloat = 0.35
    /// 速度门：速度超过 0.5 pt/ms ⇒ 判退（demo 04 口径）。
    public static let exitVelocityThreshold: CGFloat = 0.5
    /// 速度门的位移下限：位移不超过屏宽的 12% 时速度门不算数（demo 04 口径）。
    public static let velocityGateDistanceRatio: CGFloat = 0.12
    /// 速度的采样窗口长度（秒）—— 只取**最近约 90ms** 的采样（demo 04 口径）。
    public static let velocityWindow: TimeInterval = 0.09
    /// 采样间隔短于 8ms（一帧之内）时速度记 `0`（demo 04 口径）。
    public static let minimumVelocityInterval: TimeInterval = 0.008

    /// 最近一段的滑动速度（pt/ms）。
    ///
    /// 只认**最后一个采样时刻的 90ms 窗口内**的采样：手势中途的停顿不会被算进抬手速度。
    /// 窗口内不足两个采样点、时钟倒走（`dt <= 0`）、或 `dt < 8ms` ⇒ `0`。
    ///
    /// - Parameter samples: 本次手势的采样点（按时间升序）。
    /// - Returns: 有符号速度，正 = 手指向右（pt/ms）。
    public static func velocity(samples: [PanExitSample]) -> CGFloat {
        guard let last = samples.last else { return 0 }
        let recent = samples.filter { last.timestamp - $0.timestamp <= velocityWindow }
        guard let first = recent.first, recent.count >= 2 else { return 0 }
        let dt = last.timestamp - first.timestamp
        guard dt >= minimumVelocityInterval else { return 0 }
        // pt/ms：秒差先换算成毫秒。
        return (last.translation - first.translation) / CGFloat(dt * 1000)
    }

    /// 本次手势该不该退出本书。
    ///
    /// - Parameters:
    ///   - translation: 本次手势的 `DragGesture.Value.translation.width`（**不是**跟手后的
    ///     偏移）：全书第 1 页没有上一页可跟手，`PagePanTracking.panOffset` 会把位移
    ///     橡皮筋回去，用它量距离会把「够远的右滑」判成不够。
    ///   - availableWidth: 阅读区可用宽度（= 一屏可用宽）。
    ///   - samples: 本次手势的采样点（按时间升序，用来算抬手速度）。
    ///   - isBookFirstPage: 是否「全书第 1 页」（= 第 1 章第 1 页）。**为假时恒不判退**：
    ///     其它任何页的右滑仍是原有的章间导航，一个字都不许改。
    /// - Returns: `true` ⇒ 调用方直接 `dismiss()`（不做跟手位移、不播自己的回位动画）。
    public static func exitsBook(
        translation: CGFloat,
        availableWidth: CGFloat,
        samples: [PanExitSample],
        isBookFirstPage: Bool
    ) -> Bool {
        guard isBookFirstPage else { return false }
        let distance = abs(translation)
        if distance > availableWidth * exitDistanceRatio {
            return true
        }
        guard distance > availableWidth * velocityGateDistanceRatio else { return false }
        return abs(velocity(samples: samples)) > exitVelocityThreshold
    }
}
