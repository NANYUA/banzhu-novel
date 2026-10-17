import SwiftUI

/// 书架工具栏的「导入 TXT」按钮 —— **只管点击，不持有任何呈现状态**。
///
/// ## 为什么把 `.fileImporter` / `.sheet` 从这里挪走（owner 2026-10-17 真机反馈）
/// 第一版是「按钮自己带 `@State` + `.fileImporter` + `.sheet(item:)`」，
/// 而按钮是 `ToolbarItem` 的内容 —— 真机表现是**点了 txt 没有任何反应**：
/// 工具栏里的子视图不是稳定宿主，挂在它上面的呈现（picker / sheet）可能起不来。
/// 现在状态归 `BookshelfView`，呈现挂在它的内容层（`BookshelfView+Import.swift`），
/// 工具栏只负责「把开关打开」。
struct ImportTXTButton: View {
    /// 点一下要做什么（由书架把 picker 开关置为 `true`）。
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "square.and.arrow.down")
        }
        .accessibilityLabel("导入 TXT")
    }
}
