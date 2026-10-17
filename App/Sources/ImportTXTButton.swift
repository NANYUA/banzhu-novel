import ComposableArchitecture
import NovelCore
import SwiftUI
import UniformTypeIdentifiers

/// 书架工具栏的「导入 TXT」入口：选文件 → 弹导入 sheet。
///
/// ## 为什么单独成一个文件 / 一个 View
/// 1. `BookshelfView.swift` 已 556 行（`PROJECT_MAP.md` §4 红线 600，CI 的 `file_length` 一过就红），
///    入口自带 `@State`，塞回去必然顶线；
/// 2. 「选文件」是纯视图行为（`.fileImporter` 只能挂在 View 上），
///    与书架的业务状态无关，独立出来也不污染书架页。
///
/// ## 为什么用 `.sheet(item:)` 而不是 `.sheet(isPresented:)`
/// 选中文件后要**带着 URL** 进下一步。`isPresented` 还得再存一个可选 URL 并处理
/// 「URL 有、开关没开」的中间态；`item:` 用同一条路径解决。
struct ImportTXTButton: View {
    /// 导入成功后回调（书架据此重拉列表）。
    let onImported: () -> Void

    @State private var isPicking = false
    @State private var picked: PickedImportFile?

    var body: some View {
        Button {
            isPicking = true
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .accessibilityLabel("导入 TXT")
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            picked = PickedImportFile(url: url)
        }
        .sheet(item: $picked) { file in
            ImportSheet(fileURL: file.url) {
                picked = nil
                onImported()
            }
        }
    }
}

/// `.sheet(item:)` 的载体。`id` 用 URL 本身：同一个文件重复选也能重新弹。
private struct PickedImportFile: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}
