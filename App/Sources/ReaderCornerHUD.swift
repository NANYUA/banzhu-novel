import ComposableArchitecture
import NovelCore
import SwiftUI
import UIKit

/// 阅读页角落状态标签（HUD）的电池监视器。
///
/// ⚠️ `UIDevice` 属 UIKit ⇒ 它只能住在 `App/Sources/`（`Packages/` 内禁止 `import UIKit`）。
///
/// 用 `ObservableObject` 而不是 `@Observable`：后者的宏在本项目 CI 上不可用
/// （Xcode 16.4 + macos-15 runner 下宏插件报 `produced malformed response`，见 `CLAUDE.md`），
/// 手写 `ObservableObject` + `@StateObject` 是本项目既有的同类做法（`GuardView` 的
/// `ManualGuardWebController`）。
///
/// ⚠️ `batteryLevel` 在**没打开监视**时恒为 `-1`（不是「0%」）⇒ 读之前必须
/// `isBatteryMonitoringEnabled = true`；阅读页消失时必须复位为 `false`
/// —— 常开会持续耗电，而阅读页之外没有任何消费者（`ReaderCornerHUD` 负责开与关）。
@MainActor
final class BatteryMonitor: ObservableObject {
    /// 电量；`-1` = 无数据（模拟器 / 监视尚未打开）。**不许**把它当 0 用。
    @Published private(set) var level: Float = -1
    /// 充电 / 已充满时换成带闪电的电池图形。
    @Published private(set) var state: UIDevice.BatteryState = .unknown

    /// 打开监视并立刻取一次当前值（`ReaderCornerHUD` 的 `onAppear`）。
    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
    }

    /// 关掉监视（`ReaderCornerHUD` 的 `onDisappear`）—— 离开阅读页就复位，不长期开着。
    func stop() {
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    /// 取一次当前值。之后由 `batteryLevelDidChangeNotification` /
    /// `batteryStateDidChangeNotification` 两个订阅驱动（订阅在 `ReaderCornerHUD` 里）。
    func refresh() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
    }
}

/// 阅读页角落状态标签（HUD）：左上 = 书名 / 章节名，左下 = 电池，右下 = 当前页 / 总页数。
///
/// ## 常显，且画在控制栏**下层**
/// 它是与正文层、控制栏层**并列**的独立叠加层 —— `ReaderView.body` 的 ZStack 里加在
/// `if isChromeVisible { … }` **之前**。控制栏是圆角浮动面板，与 HUD 落在同样两个角上，
/// owner 口径是「呼出控制栏时盖住 HUD」⇒ HUD 必须在控制栏下层。它因此**不进**
/// `if isChromeVisible`，也不带任何显隐动画（常显，不受控制栏显隐影响）。
///
/// ## 不改变正文排版
/// 叠加层不参与正文布局、不占正文空间、不改任何 `padding` / `frame` / 分页参数
/// ⇒ 呼出控制栏不改变正文分页与阅读位置。
///
/// ## 整块不可点 ⇒ HIG 的「触控目标 ≥ 44×44pt」**不适用**
/// 纯展示，整块 `.allowsHitTesting(false)`（不抢手势层与控制栏的命中）。
/// 44pt 那条规则针对**可点**元素，这里刻意不为凑 44pt 把 HUD 撑大。
///
/// ## 前景色
/// 由调用方传入**正文文字的唯一颜色来源**
/// （`PaginationConfiguration.textColorMode.uiColor(on:custom:)`，正文在 `ReaderPageTextView`
/// 用的就是这一条）⇒ 本视图不新造颜色派生、不硬编码色值、不引用控制栏的 `ReaderChromeStyle`。
///
/// ## 无障碍
/// 整块**不** `.accessibilityHidden(true)`：页码（第几页 / 共几页）在别处都没有，
/// 藏掉等于把这条信息从 VoiceOver 用户那里删掉。页码格给一句完整中文读法
/// （否则「3/12」会被念成「三斜杠十二」）；电池格也合成一个元素给中文标签
/// （否则 VoiceOver 会念 SF Symbol 的英文符号名）。
struct ReaderCornerHUD: View {
    /// 左上：章节第一页是书名，其余页是章节名。空串 ⇒ 该格不渲染。
    let topText: String
    /// 右下：`(当前页序号, 0 起, 本章总页数)`；`nil` = 还没分页（`pages` 为空）
    /// ⇒ 页码格不渲染，**绝不**显示 `1/0` 或 `0/0`。
    let page: (index: Int, count: Int)?
    /// 正文文字色（唯一来源见类型注释）。
    let textColor: Color

    @StateObject private var battery = BatteryMonitor()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(topText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.Spacing.xxs) {
                batteryLabel
                Spacer(minLength: 0)
                pageLabel
            }
        }
        // 字号一律用文本样式（HIG：Dynamic Type 要能缩放），不用固定字号。
        .font(.caption)
        .foregroundStyle(textColor)
        .allowsHitTesting(false)
        .onAppear { battery.start() }
        // 离开阅读页就把监视关掉（`batteryLevel` 常开会持续耗电）。
        .onDisappear { battery.stop() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
        ) { _ in
            battery.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
        ) { _ in
            battery.refresh()
        }
    }
}

private extension ReaderCornerHUD {
    // MARK: - 左下：电池

    /// 电池图形 + 百分比数字（例：电池图标 + 「82%」；充电中换成带闪电的图形）。
    ///
    /// 降级规则（先定死再写码）：`batteryLevel < 0`（模拟器 / 无数据）时**只画中性电池图形、
    /// 不画百分比数字** —— `-1` 不是「0%」，绝不能显示成「-1%」或「0%」。
    private var batteryLabel: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: batterySymbol)
            if let percentText {
                Text(percentText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(batteryAccessibilityLabel)
    }

    /// 图形取**最近的**四分之一档（0.875 / 0.625 / 0.375 / 0.125 是各档区间的下界）。
    ///
    /// 符号名刻意用 iOS 13 就有的 `battery.*`：本项目最低 iOS 17，但 `battery.*percent`
    /// 系列是 iOS 17 才有的，没必要为此冒险。
    private var batterySymbol: String {
        if battery.state == .charging || battery.state == .full {
            return "battery.100.bolt"
        }
        // 无电量数据 ⇒ 只画中性轮廓、不配数字（见 `batteryLabel` 的降级规则）。
        // ⚠️ **假设**（需真机 / 模拟器确认观感）：`battery.0` 是 iOS 13 这套符号里唯一不带档位
        // 含义的电池轮廓，故拿它当「没有读数」的图形 —— 配上「没有数字」应读作无数据而非 0%。
        guard battery.level >= 0 else { return "battery.0" }
        switch battery.level {
        case 0.875...: return "battery.100"
        case 0.625...: return "battery.75"
        case 0.375...: return "battery.50"
        case 0.125...: return "battery.25"
        default: return "battery.0"
        }
    }

    /// 百分比文字；无数据时为 `nil`（该格只剩图形，见 `batteryLabel` 的降级规则）。
    private var percentText: String? {
        guard battery.level >= 0 else { return nil }
        return "\(Int((battery.level * 100).rounded()))%"
    }

    private var batteryAccessibilityLabel: String {
        guard let percentText else { return "电量未知" }
        return "电量 \(percentText)"
    }

    // MARK: - 右下：页码

    /// 当前页 / 本章总页数。阅读页只有分页模式（没有滚动模式）⇒ 这个比值恒有意义，
    /// 不需要为滚动模式做分支；唯一的降级是「还没分页」⇒ `page == nil` ⇒ 该格不渲染。
    @ViewBuilder
    private var pageLabel: some View {
        if let page {
            Text("\(page.index + 1)/\(page.count)")
                .accessibilityLabel("第 \(page.index + 1) 页，共 \(page.count) 页")
        }
    }
}

// MARK: - 与 ReaderView 的接线

extension ReaderView {
    /// 阅读页的角落状态标签层（HUD）。
    ///
    /// ⚠️ 调用点必须把它加在控制栏层**之前**（`ReaderView.body` 的 ZStack）：控制栏是圆角浮动
    /// 面板，与 HUD 落在同样两个角上，owner 口径是「呼出控制栏时盖住 HUD」⇒ HUD 画在下层；
    /// 它也因此**不进** `if isChromeVisible`（常显，不受控制栏显隐影响，也没有显隐动画）。
    ///
    /// 外留边刻意与控制栏同一套 ⇒ 控制栏一呼出就正好盖住它：上边距由调用方传入**同一个**
    /// `topBarPadding(safeAreaInsets:)` 的结果（在这里重算一份就成了第二套定位来源，日后必然
    /// 漂移），下 = `Spacing.xs`（下栏面板底边），左右 = 安全区 + **「标签边距」设置项**
    /// （`PaginationConfiguration.hudHorizontalInset`，设置页那个 0…64 的滑杆；
    /// 默认 16 = `Spacing.md`，与硬编码时代逐值相同）。
    ///
    /// ⚠️ 三个标签**共用**那一个左右值（一条 `.padding(.horizontal)` 同时管住左上 / 左下 / 右下）；
    /// **垂直位置不受它影响** —— 上仍走 `topBarPadding`、下仍走 `Spacing.xs`。
    ///
    /// 整层不参与正文布局、不占正文空间、不改任何 `padding` / `frame` / 分页参数。
    func readerCornerHUD(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>,
        pageColor: UIColor,
        safeAreaInsets: EdgeInsets,
        topPadding: CGFloat
    ) -> some View {
        ReaderCornerHUD(
            topText: cornerHUDTopText(viewStore),
            page: cornerHUDPage(viewStore),
            // 前景色复用**正文文字的唯一来源**（正文在 `ReaderPageTextView` 用的就是这一条）：
            // 不新造颜色派生、不硬编码色值、不引用控制栏的 `ReaderChromeStyle`。
            textColor: Color(uiColor: viewStore.config.textColorMode.uiColor(
                on: pageColor,
                custom: viewStore.config.customTextColor
            ))
        )
        .padding(.leading, safeAreaInsets.leading)
        .padding(.trailing, safeAreaInsets.trailing)
        .padding(.horizontal, viewStore.config.hudHorizontalInset)
        .padding(.top, topPadding)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    /// 左上角标签文字（owner 口径）：**章节第一页**显示书名，其余页显示章节名。
    /// 书名为空串时回退章节名（`init(store:)` 那条测试 / 预览路径没有书名，不能留一格空白）。
    private func cornerHUDTopText(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> String {
        let text = viewStore.currentPageIndex == 0 ? bookTitle : viewStore.chapterName
        return text.isEmpty ? viewStore.chapterName : text
    }

    /// 右下角标签：`(当前页序号（0 起）, 本章总页数)`；`pages` 为空（正文还没排完）⇒ `nil`，
    /// 那一格不渲染 —— **绝不**显示 `1/0`。阅读页只有分页模式，这个比值恒有意义，不需要分支。
    private func cornerHUDPage(
        _ viewStore: ViewStore<ReaderFeature.State, ReaderFeature.Action>
    ) -> (index: Int, count: Int)? {
        let pages = viewStore.pages
        guard !pages.isEmpty else { return nil }
        return (viewStore.currentPageIndex, pages.count)
    }
}
