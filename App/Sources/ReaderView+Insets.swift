import SwiftUI

// 阅读页**竖向边距的唯一解析处**：把设置值解析成上栏面板上边缘距屏幕顶的实际距离
// （下栏那一侧由 `ReaderChromeOverlay.bottomBarInset` 直接用设定值，见那里的说明）。
//
// 从 `ReaderView.swift` 拆出来的：那个文件已贴近 SwiftLint `file_length` 600 的硬门。
// 与 `ReaderView+PageTurn.swift` 同一处理：成员原本是 `private`（Swift 的 `private` 是
// **文件级**的），拆文件后改为**模块内可见**。
//
// ⚠️ 曾经的「自动」档（`nil` ⇒ `max(Spacing.xs, 安全区top − 34)`，灵动岛机型 ≈ 25pt）
// 已按 owner 2026-10-11 口径**整体删除**：默认值改成 `0`（贴屏幕最边缘）、范围 `-70 ... 70`
// ⇒ 这里只剩「设置值 → 面板实际边距」这一条解析，全仓没有第二套公式、也不再吃安全区。

extension ReaderView {
    /// 上栏面板的上边距 = 设置里的「上标签上边距」（`PaginationConfiguration.topBarInset`）。
    ///
    /// 语义（owner 2026-10-11 口径）：
    /// - `0` = 上栏面板的上边缘**贴到屏幕最上边**（**不避让灵动岛 / 状态栏**，面板会被缺口
    ///   盖住 —— 这正是 owner 要的默认值，⛔ 别当成 bug 改回去）；
    /// - **负值** = 面板整体**移出屏幕上边**（`-70` = 再往上 70pt，一部分露在屏幕外）；
    /// - 正值 = 距屏幕顶的绝对距离。
    ///
    /// ⇒ 这里**不做**任何 `max(下限, …)` 夹取：`0` 与负值都是有效值，不是「未设置」。
    /// 布局侧同样不夹：结果直接交给 `ReaderChromeOverlay` 的 `.padding(.top, …)`，
    /// 负 padding 会把面板推到容器外（SwiftUI 不截断、控制栏层也没有 `.clipped()`）。
    ///
    /// `nil` = 老数据里没有这个 key ⇒ 按 `0`（与 `mergedConfiguration` 的兜底同值）。
    /// ⚠️ 角落 HUD 传的是**同一个**调用结果（见 `readerCornerHUD`）—— 重算一份就是第二套定位来源。
    func topBarPadding(inset: CGFloat?) -> CGFloat {
        inset ?? 0
    }
}
