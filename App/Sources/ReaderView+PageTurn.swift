import NovelCore
import SwiftUI

/// 阅读页的翻页转场与动画。
///
/// 从 `ReaderView.swift` 拆出来的：那个文件已经贴近 SwiftLint `file_length` 600 的硬门，
/// 而这两段是其中最独立、最纯的动画逻辑，搬走不改任何行为。
///
/// 注意：这些成员原本是 `private`（Swift 的 `private` 是本文件级的），
/// 拆文件后改为**模块内可见**，`reduceMotion` 也同步放开为模块内可见。
extension ReaderView {
    /// 翻页转场：Reduce Motion 下退化为纯透明度（§13）。
    func pageTransition(
        for animation: PageTurnAnimation,
        direction: PageTurnDirection
    ) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        switch animation {
        case .none:
            return .identity
        case .cover:
            if direction == .forward {
                return .asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .leading)
                )
            } else {
                return .asymmetric(
                    insertion: .move(edge: .leading),
                    removal: .move(edge: .trailing)
                )
            }
        case .curl:
            if direction == .forward {
                return .asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity)
                )
            } else {
                return .asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.94, anchor: .trailing).combined(with: .opacity)
                )
            }
        }
    }

    /// 翻页动画：§8 用可中断的临界阻尼弹簧；Reduce Motion 退化为短淡入淡出（§13）。
    func pageAnimation(for animation: PageTurnAnimation) -> Animation? {
        if reduceMotion {
            return .easeInOut(duration: 0.2)
        }
        switch animation {
        case .none:
            nil
        case .cover:
            .spring(response: 0.3, dampingFraction: 1)
        case .curl:
            .spring(response: 0.35, dampingFraction: 1)
        }
    }
}
