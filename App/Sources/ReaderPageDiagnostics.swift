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
/// ## 怎么删（提交前整块删干净，共 3 处）
/// 1. 删本文件 `App/Sources/ReaderPageDiagnostics.swift`；
/// 2. `App/Sources/ReaderView.swift`：删那一行 `.readerPageDiagnostics(page:pageCount:)`；
/// 3. `App/Sources/ReaderPageTextView.swift`：删 `pageBoxWidth` 属性、`makeUIView` 与
///    `updateUIView` 里各一行 `pageBoxWidth = …`、`layoutSubviews` 里的 `captureDiagnostics()`
///    调用、以及 `captureDiagnostics()` 方法本身。
enum ReaderPageDiagnostics {
    /// 总开关（编译期常量）：诊断构建置 `true`；删本文件时它一起消失，**不影响正式逻辑**
    /// （`false` 时下面的分支会被编译器整个去掉）。
    static let isEnabled = true

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
/// 放在**左上角**（不遮正文末行 —— owner 要看的正是页面底部那一行）。
struct ReaderPageDiagnosticsOverlay: View {
    /// 当前页下标（0 基）与总页数，由调用方从 `ReaderFeature.State` 传入。
    let page: Int
    let pageCount: Int

    var body: some View {
        if ReaderPageDiagnostics.isEnabled {
            TimelineView(.periodic(from: .now, by: 0.4)) { _ in
                panel(ReaderPageDiagnostics.snapshot)
            }
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        .padding(DesignTokens.Spacing.xs)
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
    func readerPageDiagnostics(page: Int, pageCount: Int) -> some View {
        overlay(alignment: .topLeading) {
            ReaderPageDiagnosticsOverlay(page: page, pageCount: pageCount)
        }
    }
}
