import ComposableArchitecture
import Foundation
@testable import NovelCore
import XCTest

/// 导入流程状态机测试（不碰文件系统、不碰 SwiftData：导入器被替身掉）。
@MainActor
final class ImportFeatureTests: XCTestCase {
    private func makeStore(
        fileURL: URL = URL(fileURLWithPath: "/tmp/第一章 起点.txt"),
        importer: LocalBookImporter
    ) -> TestStore<ImportFeature.State, ImportFeature.Action> {
        TestStore(initialState: ImportFeature.State(fileURL: fileURL)) {
            ImportFeature()
        } withDependencies: {
            $0.localBookImporter = importer
            $0.importRuleStore = ImportRuleStore(load: { [] }, save: { _ in })
        }
    }

    func test书名初值取文件名() {
        let state = ImportFeature.State(fileURL: URL(fileURLWithPath: "/tmp/斗破.txt"))
        XCTAssertEqual(state.title, "斗破")
        XCTAssertEqual(state.fileName, "斗破.txt")
        XCTAssertTrue(state.canStart)
    }

    func test书名空白时不能开始() async {
        let store = makeStore(importer: LocalBookImporter { _, _ in
            XCTFail("不该被调用")
            return ImportResult(bookPath: "local/x/", title: "x", chapterCount: 0)
        })
        await store.send(.titleChanged("   ")) {
            $0.title = "   "
        }
        XCTAssertFalse(store.state.canStart)
        await store.send(.startTapped)
    }

    func test开始导入_进度与成功() async {
        let result = ImportResult(bookPath: "local/abc/", title: "起点", chapterCount: 2)
        let store = makeStore(importer: LocalBookImporter { _, onProgress in
            await onProgress(.reading)
            await onProgress(.writing(done: 1, total: 2))
            return result
        })
        await store.send(.titleChanged("起点")) { $0.title = "起点" }
        await store.send(.startTapped) {
            $0.phase = .working
            $0.statusText = "正在读取文件…"
            $0.writtenCount = 0
            $0.chapterTotal = 0
            $0.errorMessage = nil
        }
        await store.receive(.progress(.reading))
        await store.receive(.progress(.writing(done: 1, total: 2))) {
            $0.writtenCount = 1
            $0.chapterTotal = 2
            $0.statusText = "正在写入第 1/2 章…"
        }
        await store.receive(.succeeded(result)) {
            $0.phase = .finished
            $0.importedChapterCount = 2
            $0.writtenCount = 2
            $0.chapterTotal = 2
            $0.statusText = nil
            $0.errorMessage = nil
        }
    }

    func test导入失败_给出人话原因() async {
        let store = makeStore(importer: LocalBookImporter { _, _ in
            throw ImportError.alreadyExists(title: "起点")
        })
        await store.send(.startTapped) {
            $0.phase = .working
            $0.statusText = "正在读取文件…"
            $0.writtenCount = 0
            $0.chapterTotal = 0
            $0.errorMessage = nil
        }
        await store.receive(.failed("《起点》已经在书架里了。")) {
            $0.phase = .failed
            $0.errorMessage = "《起点》已经在书架里了。"
            $0.statusText = nil
        }
    }

    func test失败后重试回到表单() async {
        let store = makeStore(importer: LocalBookImporter { _, _ in
            throw ImportError.cannotRead(fileName: "起点")
        })
        await store.send(.startTapped) {
            $0.phase = .working
            $0.statusText = "正在读取文件…"
            $0.writtenCount = 0
            $0.chapterTotal = 0
            $0.errorMessage = nil
        }
        await store.receive(.failed("读不到《起点》，请重新选择文件。")) {
            $0.phase = .failed
            $0.errorMessage = "读不到《起点》，请重新选择文件。"
            $0.statusText = nil
        }
        await store.send(.retryTapped) {
            $0.phase = .form
            $0.errorMessage = nil
            $0.statusText = nil
        }
        XCTAssertTrue(store.state.canStart)
    }

    /// sheet 被关掉 ⇒ effect 被取消 ⇒ **不产生失败态**（界面随 sheet 一起消失）。
    func test取消不算失败() async {
        let store = makeStore(importer: LocalBookImporter { _, _ in
            throw CancellationError()
        })
        await store.send(.startTapped) {
            $0.phase = .working
            $0.statusText = "正在读取文件…"
            $0.writtenCount = 0
            $0.chapterTotal = 0
            $0.errorMessage = nil
        }
        await store.finish()
        XCTAssertEqual(store.state.phase, .working)
        XCTAssertNil(store.state.errorMessage)
    }
}
