import SwiftUI

/// 阅读页的翻页转场与动画。
///
/// 从 `ReaderView.swift` 拆出来的：那个文件已经贴近 SwiftLint `file_length` 600 的硬门，
/// 而这两段是其中最独立、最纯的动画逻辑，搬走不改任何行为。
///
/// 注意：这些成员原本是 `private`（Swift 的 `private` 是本文件级的），
/// 拆文件后改为**模块内可见**，`reduceMotion` 也同步放开为模块内可见。
///
/// `PageTurnAnimation` 只剩 `.none`（`cover` / `curl` 已删，owner 决定），所以原先按
/// 动画方式与方向分派的 `switch` 一并删除：两个函数不再需要参数，行为固定成
/// 「不叠换页动画 + 恒等转场」，Reduce Motion 时仍各自退化（§13）。
extension ReaderView {
    /// 翻页转场：Reduce Motion 下退化为纯透明度（§13），否则恒等（`.none` 的唯一行为）。
    func pageTransition() -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .identity
    }

    /// 翻页动画：**普通缓动，不用弹簧**（U1-9，owner 要求删掉翻页的弹簧效果）。
    ///
    /// 原先这里是 `.spring(response:dampingFraction: 1)`（临界阻尼，其实没有回弹），
    /// 现在统一换成缓动曲线，让「翻页」这条链路上不再出现任何弹簧。
    /// 唯一取值 `.none` ⇒ 不叠换页动画（返回 `nil`）；
    /// Reduce Motion 仍退化为更短的淡入淡出（§13）。
    func pageAnimation() -> Animation? {
        if reduceMotion {
            return .easeInOut(duration: 0.2)
        }
        return nil
    }
}
