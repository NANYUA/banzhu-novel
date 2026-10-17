import SwiftUI
import UniformTypeIdentifiers

/// 选中的 txt 文件。`.sheet(item:)` 的载体：`id` 用 URL 本身，同一个文件重复选也能重新弹。
struct PickedImportFile: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

extension View {
    /// 把「选文件 → 填书名 → 导入」这套呈现挂到**内容层**上。
    ///
    /// 状态由调用方持有（`isPickingImportFile` / `pickedImportFile` / `importFailureMessage`），
    /// 这里只做修饰符拼装 —— 原因见 `ImportTXTButton` 的注释：挂在工具栏子视图上的
    /// `.fileImporter` / `.sheet` 真机上点不出来。
    ///
    /// ⚠️ 当前唯一调用点是 `DownloadSettingsView`（下载设置页，owner 2026-10-17 第二轮口径：
    /// 「将导入书籍按钮放在本地页面右上角设置中」），**不是** `BookshelfView`；
    /// 文件名沿用旧名是因为改动只允许改内容、不允许在提交里出现重命名。
    func importHost(
        isPicking: Binding<Bool>,
        picked: Binding<PickedImportFile?>,
        failureMessage: Binding<String?>,
        onImported: @escaping () -> Void
    ) -> some View {
        modifier(
            ImportHostModifier(
                isPicking: isPicking,
                picked: picked,
                failureMessage: failureMessage,
                onImported: onImported
            )
        )
    }
}

/// `.fileImporter` + 导入 sheet + 「选文件失败」的提示。
private struct ImportHostModifier: ViewModifier {
    @Binding var isPicking: Bool
    @Binding var picked: PickedImportFile?
    @Binding var failureMessage: String?
    let onImported: () -> Void

    /// 失败提示是否展示（`failureMessage != nil` 即展示）。
    private var isShowingFailure: Binding<Bool> {
        Binding(
            get: { failureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    failureMessage = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPicking,
                // ⚠️ 用 `.item` 而不是 `.plainText` / `.text`：某些来源的 txt（其它 App 分享进来、
                // 没有扩展名、Dynamic UTI）会被 `.plainText` 判成不可选 —— 在文件选择器里**是灰的、
                // 点了没反应**（owner 2026-10-17 真机反馈）。能不能读由 `TextDecoder` 判，
                // 选之前不做过早过滤。
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else {
                        failureMessage = "没有选中任何文件。"
                        return
                    }
                    picked = PickedImportFile(url: url)
                case let .failure(error):
                    // 失败必须说话：静默 return 在用户眼里就是「点了没反应」。
                    failureMessage = error.localizedDescription
                }
            }
            .sheet(item: $picked) { file in
                ImportSheet(fileURL: file.url) {
                    picked = nil
                    onImported()
                }
            }
            .alert("打不开这个文件", isPresented: isShowingFailure) {
                Button("好") { failureMessage = nil }
            } message: {
                Text(failureMessage ?? "")
            }
    }
}
