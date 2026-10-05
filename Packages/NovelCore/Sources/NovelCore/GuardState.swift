import Foundation

/// 过盾状态（2026-10-05 从 `NovelEngine` 拆出）。
///
/// ## 为什么搬到这里
///
/// 原先它待在引擎层，带来两个问题：
/// 1. **状态管理越界**：带 `ObservableObject` / `@Published`，
///    而 D2 已定状态管理归 Core（TCA）
/// 2. **UI 语义泄漏进引擎**：`showManual`（要不要弹手动验证页）、
///    `reloadToken`（通知界面重载）都是界面概念，引擎不该知道
///
/// ## 拆分后的契约
/// - `NovelEngine.GuardResolver.autoPass()` → 只返回 **Bool**（过盾成功与否）
/// - 界面要不要弹窗、何时重载 → 归本层
///
/// ## ⚠️ 待改造
/// 当前是占位实现。后续改为 **TCA 状态**（D2 已定）。
public final class GuardState {
    public static let shared = GuardState()

    /// 自动过盾失败、需要用户手动拖滑块 → 界面弹出手动验证页
    public var showManual = false

    /// 正在自动过盾中
    public var autoPassing = false

    /// 每次从手动验证页返回时 +1；各页面监听它，返回后立即重新加载
    public private(set) var reloadToken = 0

    /// 手动验证页关闭后调用：同步 Cookie 并通知各页面立即重载
    public func didReturnFromManual() {
        reloadToken += 1
    }
}
