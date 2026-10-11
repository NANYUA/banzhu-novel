import SwiftUI

// 阅读页**竖向边距的解析**：上栏面板离屏幕顶多远、下栏面板离屏幕底多远
// （下栏那一侧由 `ReaderChromeOverlay.bottomBarInset` 直接用设定值，见那里的说明）。
//
// 从 `ReaderView.swift` 拆出来的：那个文件已贴近 SwiftLint `file_length` 600 的硬门
// （拆前 607 行 —— 本轮给它加了「上标签上边距 / 下标签下边距」两个设置项），
// 而这一块是自成一体的「几何解析」，与正文布局（`readerContentPaddings` /
// `readerContentSize`）和控制栏视图都零耦合。
// 与 `ReaderView+PageTurn.swift` 同一处理：成员原本是 `private`（Swift 的 `private` 是
// **文件级**的），拆文件后改为**模块内可见**。
//
// ## 为什么「自动」值必须在这里（App 层）算
// NovelCore 拿不到安全区（那是 UIKit / SwiftUI 的事）⇒ `PaginationConfiguration.topBarInset`
// 只能是 `CGFloat?`：`nil` = **自动**，由这里解析成具体数字（见 `autoTopBarPadding`）。
// 也正因为「`nil` = 改造前的公式」，新增这两个设置项**不需要任何迁移 key**。

extension ReaderView {
    /// 上栏最多可上移的量：理论极限 ≈ 38pt（栏顶 21pt）只剩 0.7pt 余量，太紧 —— 字体度量是
    /// 查表估的，估错 1pt 标题就会被灵动岛咬 ⇒ 收紧到 34pt。推导见 `autoTopBarPadding(safeAreaInsets:)`。
    static let topBarMaxUpwardShift: CGFloat = 34

    /// 上栏的上边距：**用户设定优先**，`nil`（= 自动）才回落到安全区推导值。
    ///
    /// 语义（owner 2026-10-11 口径）：**距屏幕顶边的绝对距离** —— `0` = 上栏面板的上边缘
    /// 贴到屏幕最上边（**不避让灵动岛**，面板可被缺口盖住），`90` = 距屏幕顶 90pt。
    /// ⇒ 这里**不做**任何 `max(下限, …)` 夹取：`0` 是有效值，不是「未设置」。
    ///
    /// ⚠️ 它只作用在**上栏面板**上（控制栏这一层不吃竖向安全区，见 `ReaderView.body`）；
    /// 跳章条与下栏的下边缘由 `ReaderChromeOverlay.bottomBarInset` 决定。
    /// ⚠️ 角落 HUD 传的是**同一个**调用结果（见 `readerCornerHUD`）—— 重算一份就是第二套定位来源。
    func topBarPadding(safeAreaInsets: EdgeInsets, inset: CGFloat?) -> CGFloat {
        inset ?? autoTopBarPadding(safeAreaInsets: safeAreaInsets)
    }

    /// 「自动」上栏上边距（U9-7 的原始公式，**逐字未改**）：
    /// `T = max(Spacing.xs, safeAreaInsets.top − 34)`。
    ///
    /// 上栏的**标题是居中**的，与灵动岛同一列 ⇒ 标题字形必须落在灵动岛下沿（约 48pt）以下。
    /// 栏内结构是「`Spacing.sm`(12) 内边距 + 44pt 内容行 + 12 内边距」，标题在 44pt 行内垂直
    /// 居中，其字形顶距栏顶约 27pt ⇒ 栏顶 ≥ 48 − 27 ≈ 21pt 即可（理论上限 59 − 21 ≈ 38pt，
    /// 但那样只剩 0.7pt 余量）。取 34pt ⇒ 栏顶 59 − 34 = **25pt**，标题字形顶 ≈ 25 + 27 = 52pt，
    /// 距下沿约 **5.7pt**。栏顶仍进到灵动岛覆盖区（25pt < 48pt）—— 那是预期的：被覆盖的
    /// 那部分是面板的**空内边距**。下限 `Spacing.xs`(8) 保证无灵动岛 / 无刘海机型上面板也不贴死屏幕边。
    ///
    /// ⚠️ 这是**自动**状态（`config.topBarInset == nil`）的回落值，同时被设置页用来显示
    /// 本机当前值（`ReaderView.autoTopBarInset`）—— 两处必须是同一个函数，
    /// 否则滑杆读数与面板位置会不一致。
    func autoTopBarPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        max(DesignTokens.Spacing.xs, safeAreaInsets.top - Self.topBarMaxUpwardShift)
    }
}
