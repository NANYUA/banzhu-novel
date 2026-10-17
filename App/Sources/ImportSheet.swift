import ComposableArchitecture
import NovelCore
import SwiftUI

/// txt 导入 sheet：填书名 / 作者 → 显示进度 → 成功或失败。
///
/// ## 状态归属
/// 表单与进度全在 `ImportFeature`（NovelCore）里，本文件只负责画。
/// 这样「切章 → 落盘 → 落库」这条链路的每个中间态都能在 `NovelCoreTests` 里用
/// `TestStore` 验证，不需要跑模拟器。
struct ImportSheet: View {
    @State private var store: StoreOf<ImportFeature>
    private let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(fileURL: URL, onFinished: @escaping () -> Void) {
        _store = State(
            initialValue: Store(initialState: ImportFeature.State(fileURL: fileURL)) {
                ImportFeature()
            }
        )
        self.onFinished = onFinished
    }

    var body: some View {
        WithViewStore(store, observe: { $0 }) { viewStore in
            NavigationStack {
                Form {
                    switch viewStore.phase {
                    case .form:
                        formContent(viewStore)
                    case .working:
                        progressContent(viewStore)
                    case .finished:
                        finishedContent(viewStore)
                    case .failed:
                        failedContent(viewStore)
                    }
                }
                .navigationTitle("导入 TXT")
                .navigationBarTitleDisplayMode(.inline)
                // 导入中禁止下滑关闭：中途关掉会让用户以为导入完成了。
                .interactiveDismissDisabled(viewStore.isWorking)
                .toolbar {
                    toolbarContent(viewStore)
                }
            }
        }
    }

    // MARK: - 四种状态

    private func formContent(_ viewStore: ViewStore<ImportFeature.State, ImportFeature.Action>) -> some View {
        Section("文件") {
            LabeledContent("文件", value: viewStore.fileName)
        }
        Section("书籍信息") {
            TextField("书名", text: viewStore.binding(get: \.title, send: ImportFeature.Action.titleChanged))
            TextField(
                "作者（可留空）",
                text: viewStore.binding(get: \.author, send: ImportFeature.Action.authorChanged)
            )
        }
        Section {
            Text("章节按「设置 → 导入目录正则」里启用的规则切分；一条规则都没命中时，按 3000 字自动分章。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func progressContent(_ viewStore: ViewStore<ImportFeature.State, ImportFeature.Action>) -> some View {
        Section {
            if viewStore.chapterTotal > 0 {
                ProgressView(
                    value: Double(viewStore.writtenCount),
                    total: Double(viewStore.chapterTotal)
                )
            } else {
                ProgressView()
            }
            if let status = viewStore.statusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("正在导入")
        } footer: {
            Text("导入过程需要写入每一章正文，请保持本页打开。")
        }
    }

    private func finishedContent(_ viewStore: ViewStore<ImportFeature.State, ImportFeature.Action>) -> some View {
        Section {
            Label("导入完成", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            LabeledContent("章节数", value: "\(viewStore.importedChapterCount)")
        } footer: {
            Text("这本书已加入书架，全部章节都在本地，不需要联网。")
        }
    }

    private func failedContent(_ viewStore: ViewStore<ImportFeature.State, ImportFeature.Action>) -> some View {
        Section {
            Label("导入失败", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let message = viewStore.errorMessage {
                Text(message)
                    .font(.footnote)
            }
        } footer: {
            Text("可以返回修改书名后再试；已经写入的临时正文会被清理。")
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private func toolbarContent(
        _ viewStore: ViewStore<ImportFeature.State, ImportFeature.Action>
    ) -> some ToolbarContent {
        switch viewStore.phase {
        case .form:
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("开始导入") { viewStore.send(.startTapped) }
                    .disabled(!viewStore.canStart)
            }
        case .working:
            // 关闭 = 取消 effect（TCA 会随 Store 释放取消那个 `.run`），
            // 已经写了一半的正文由 `LocalBookImporterLive` 自己清理。
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        case .finished:
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    onFinished()
                    dismiss()
                }
            }
        case .failed:
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    onFinished()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("重试") { viewStore.send(.retryTapped) }
            }
        }
    }
}
