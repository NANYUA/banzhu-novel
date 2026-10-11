import Foundation
import SwiftUI

/// ⚠️ **临时诊断件**（owner 第四轮真机反馈：「还是会有章节正文被裁剪」）。
///
/// ## 为什么要有它
/// 前两轮都是「静态读代码 ⇒ 判定度量与渲染逐值一致」，真机两次反证（第二次还证明
/// 「度量侧逐行回退」也没解决）。所以这一轮**不再盲修**：把三种可能一次摆到屏幕上 ——
/// ① 分页盒 ≠ 渲染盒（`containerSize` 是默认值 / 上一次的值）；
/// ② 本页内容排不进渲染容器（字形没排完）；
/// ③ 末行底边越出排版盒（TextKit 的行片段语义）。
/// owner 截一张图即可定位是哪一种。
///
/// ## 两条展示路径（⛔ 同一时刻只开一条）
/// - **UIKit 自绘面板（当前生效）**：`PageBoxTextView` 里的 `UILabel` 子视图 —— owner 真机上
///   SwiftUI 浮层「挂了却没渲染」（包已确认含该代码）⇒ 用子视图兜底，与 SwiftUI 的图层 / 时序无关。
///   开关 = `isUIKitPanelEnabled = true`。
/// - **SwiftUI 浮层（默认关，保留备用）**：`ReaderView.body` 最外层那条
///   `.readerPageDiagnostics(page:pageCount:)`。**要打开它**：把下面 `isEnabled` 改成 `true`，
///   同时把 `isUIKitPanelEnabled` 改成 `false`（一行常量，其余不用动）。
///
/// ## 怎么删（提交前整块删干净，共 3 处）
/// 1. 删本文件 `App/Sources/ReaderPageDiagnostics.swift`；
/// 2. `App/Sources/ReaderView.swift`：删那一行 `.readerPageDiagnostics(page:pageCount:)`；
/// 3. `App/Sources/ReaderPageTextView.swift`：删 `pageBoxWidth` 属性、`makeUIView` 与
///    `updateUIView` 里各一行 `pageBoxWidth = …`、`layoutSubviews` 里的
///    `if ReaderPageDiagnostics.isOn { captureDiagnostics() }`，以及 `captureDiagnostics()`、
///    `diagnosticsLabel`、`updateDiagnosticsLabel()`、`diagnosticsText(_:)` 四个诊断成员。
enum ReaderPageDiagnostics {
    /// SwiftUI 浮层开关（**默认关**）。owner 真机上「挂了却没渲染」（包已确认含该代码）⇒
    /// 本轮改用 `isUIKitPanelEnabled` 的 UIKit 自绘面板。
    /// 要换回 SwiftUI 浮层：本行改 `true`、下一行改 `false` 即可（其余不用动）。
    static let isEnabled = false

    /// UIKit 自绘面板开关（**当前生效路径**）：`PageBoxTextView` 里的 `UILabel` 子视图。
    /// 子视图天然画在文本之上，不依赖 SwiftUI 的 overlay / TimelineView 图层与时序。
    static let isUIKitPanelEnabled = true

    /// 数据采集总开关：两条展示路径任一开启就需要采集（`PageBoxTextView.layoutSubviews` 用它）。
    static var isOn: Bool {
        isEnabled || isUIKitPanelEnabled
    }

    /// 最近一帧的实测值：由 `PageBoxTextView` 在布局后**直接赋值**。
    ///
    /// 刻意**不用 `@Published`**：在 UIKit 布局回调里发布 SwiftUI 状态会触发
    /// 「Publishing changes from within view updates」并可能引起更新环。浮层改用
    /// `TimelineView` 每 0.4s 主动读一次，读到就是最新值。
    static var snapshot = Snapshot()

    /// 一帧的实测值（长度单位 pt；字形数单位 = 字形）。
    ///
    /// - `config*`：**分页**用的盒（`PaginationConfiguration.containerSize`）。
    /// - `bounds*`：渲染视图（`UITextView`）的实际 frame。
    /// - `container*`：真正参与排版的文本容器尺寸。
    /// - `glyphsInContainer < glyphCount` ⇒ 本页切片**排不进**这个容器（内容被丢）。
    struct Snapshot: Equatable {
        var configWidth: CGFloat = 0
        var configHeight: CGFloat = 0
        var boundsWidth: CGFloat = 0
        var boundsHeight: CGFloat = 0
        var containerWidth: CGFloat = 0
        var containerHeight: CGFloat = 0
        var glyphCount: Int = 0
        var glyphsInContainer: Int = 0
        var lineCount: Int = 0
        var textLength: Int = 0
        var lastLineUsedMaxY: CGFloat = 0
        var lastLineFragmentMaxY: CGFloat = 0
        /// 末行底边（`used` 与 `fragment` 取大者）− 容器高：`> 0` ⇒ 末行越出排版盒。
        var lastLineOverflow: CGFloat = 0
    }
}

/// 诊断浮层：只读 `ReaderPageDiagnostics.snapshot`，不改状态、不吃手势、不进读屏。
///
/// ## 三条「必须真的看得见」的保险（上一版 owner 没看到它）
/// 1. **由调用方挂到最外层**（`ReaderView.body` 最末尾那条 `.readerPageDiagnostics(...)`）——
///    不在正文层内部，正文层 / 页面背景色 / 边框都盖不住它；
/// 2. **面板不包在 `if` 里**：`TimelineView` 一出现就渲染内容（周期刷新只是附带），
///    排除「条件为假 / 首帧没触发」这类看不见的失败（开关挪到了下面的 `@ViewBuilder` 里）；
/// 3. **不透明底**（`.regularMaterial`）+ 语义前景色：浅色 / 深色下都一眼可见。
///
/// 位置：左上、**让开章节名 HUD 那一行**（下移 `Spacing.xxl`）；不遮正文末行 ——
/// owner 要看的正是页面底部那一行。
struct ReaderPageDiagnosticsOverlay: View {
    /// 当前页下标（0 基）与总页数，由调用方从 `ReaderFeature.State` 传入。
    let page: Int
    let pageCount: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            panel(ReaderPageDiagnostics.snapshot)
        }
    }

    private func panel(_ snapshot: ReaderPageDiagnostics.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            row("配置盒(分页)", "\(text(snapshot.configWidth)) × \(text(snapshot.configHeight))")
            row("渲染 bounds", "\(text(snapshot.boundsWidth)) × \(text(snapshot.boundsHeight))")
            row("排版容器", "\(text(snapshot.containerWidth)) × \(text(snapshot.containerHeight))")
            row("本页字形", "容器内 \(snapshot.glyphsInContainer) / 共 \(snapshot.glyphCount)（\(snapshot.lineCount) 行）")
            row("末行底边", "used \(text(snapshot.lastLineUsedMaxY)) · frag \(text(snapshot.lastLineFragmentMaxY))")
            row("末行越底", text(snapshot.lastLineOverflow))
            row("页", "\(page + 1) / \(pageCount)")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(DesignTokens.Spacing.xs)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        .padding(.top, DesignTokens.Spacing.xxl)
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func text(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

extension View {
    /// 叠一层临时诊断浮层（内容与开关见 `ReaderPageDiagnostics`）。
    ///
    /// 关掉时**原样返回**（不产生任何额外层）—— 用 `@ViewBuilder` 而不是在浮层内部判断，
    /// 免得「浮层里那个 `if` 为假」这种失败模式让人误以为「挂了但看不见」。
    @ViewBuilder
    func readerPageDiagnostics(page: Int, pageCount: Int) -> some View {
        if ReaderPageDiagnostics.isEnabled {
            overlay(alignment: .topLeading) {
                ReaderPageDiagnosticsOverlay(page: page, pageCount: pageCount)
            }
        } else {
            self
        }
    }
}
