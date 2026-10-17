import ComposableArchitecture
import NovelCore
import SwiftUI

/// 下载设置页。
///
/// ⚠️ 可见性是 `internal`（U9-8 起），**不是** `public`：入口已搬到
/// `BookshelfView` 的外层工具栏（仅 `showsLocalGroup` 时出现），
/// 而它就在本模块（`App` target）里，`internal` 已经够用 —— 不要为它加 `public`。
/// 本页仍由 `BookshelfView` 的 `.sheet` 里那层 `NavigationStack` 提供标题与「完成」。
struct DownloadSettingsView: View {
    let store: StoreOf<DownloadFeature>

    /// 导入完成后的收尾（书架那层：自增刷新令牌 + 重拉书架）。
    ///
    /// 入口在这里、书却在书架层：`DownloadQueueView` 只是渲染者，
    /// 刷新令牌必须由 `BookshelfView` 持有（它同时是 `DownloadQueueView` 的构造者）。
    let onImported: () -> Void

    @Environment(\.dismiss) private var dismiss

    // 导入本地 TXT：picker 开关 / 选中的文件 / 选文件失败的提示。
    //
    // ⚠️ 呈现挂在**本页内容层**（下面的 `.importHost(...)`），不要挪进工具栏 ——
    // 工具栏子视图不是稳定宿主，真机上 `.fileImporter` 点了完全没反应（owner 2026-10-17 首轮反馈）。
    @State private var isPickingImportFile = false
    @State private var pickedImportFile: PickedImportFile?
    @State private var importFailureMessage: String?

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            Form {
                Section {
                    ImportTXTButton { isPickingImportFile = true }
                } header: {
                    Text("本地导入")
                } footer: {
                    Text("选一个 txt ⇒ 按目录正则切成章节后放进「本地」，全部章节存在本地，不需要联网。")
                }

                Section {
                    Toggle(
                        "允许蜂窝网络下载",
                        isOn: Binding(
                            get: { viewStore.allowsCellular },
                            set: { viewStore.send(.setAllowsCellular($0)) }
                        )
                    )

                    Label(
                        viewStore.networkKind.title,
                        systemImage: viewStore.networkKind.icon
                    )
                    .foregroundStyle(.secondary)
                } footer: {
                    Text("关闭时只在 Wi-Fi 下开始新章节；当前请求结束后，队列会等待网络切换。")
                }

                Section {
                    Picker(
                        "下载速度",
                        selection: Binding(
                            get: { viewStore.speed },
                            set: { viewStore.send(.setSpeed($0)) }
                        )
                    ) {
                        Text("保守").tag(DownloadSpeed.conservative)
                        Text("快速").tag(DownloadSpeed.fast)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(speedDescription(for: viewStore.speed))
                }
            }
            .navigationTitle("下载设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            // 导入 TXT 的呈现宿主：picker → 填书名 sheet → 进度 / 成功 / 失败。
            // 挂在内容层（Form）上，**不要**挪进工具栏子视图（真机不生效，见 `ImportTXTButton` 注释）。
            .importHost(
                isPicking: $isPickingImportFile,
                picked: $pickedImportFile,
                failureMessage: $importFailureMessage,
                onImported: {
                    onImported()
                    // 导完就收起设置页：书已经在「本地」，停在设置页反而看不到结果。
                    dismiss()
                }
            )
        }
    }

    private func speedDescription(for speed: DownloadSpeed) -> String {
        switch speed {
        case .conservative:
            "保守档每章间隔约 0.75 秒，适合长时间批量下载。"
        case .fast:
            "快速档不设间隔，可能触发网站限制，请谨慎使用。"
        }
    }
}

private extension DownloadNetworkKind {
    var title: String {
        switch self {
        case .unknown:
            "正在检查网络"
        case .offline:
            "当前无网络"
        case .wifi:
            "当前为 Wi-Fi"
        case .cellular:
            "当前为蜂窝网络"
        case .other:
            "当前为其它网络"
        }
    }

    var icon: String {
        switch self {
        case .unknown:
            "network"
        case .offline:
            "wifi.slash"
        case .wifi:
            "wifi"
        case .cellular:
            "antenna.radiowaves.left.and.right"
        case .other:
            "network"
        }
    }
}
