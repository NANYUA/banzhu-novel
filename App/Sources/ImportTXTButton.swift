import SwiftUI

/// 「导入书籍」这一行（下载设置页里）。
///
/// ## 为什么这里只有一行按钮
/// `.fileImporter` / `.sheet` 不能挂在工具栏子视图上 —— 真机上点了完全没反应
/// （owner 2026-10-17 首轮反馈），呈现改挂在 `DownloadSettingsView` 的**内容层**
/// （`.importHost(...)`，实现在 `BookshelfView+Import.swift`）。
/// 本视图因此只负责「被点」，不持有任何呈现状态。
///
/// 入口位置也是 owner 定的：本地页右上角齿轮 → 下载设置页里，而不是书架工具栏。
struct ImportTXTButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label("导入书籍", systemImage: "square.and.arrow.down")
                // HIG §9：`.frame` 落在 label 上才撑开命中区（套在 Button 外面无效）。
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("导入书籍")
    }
}
