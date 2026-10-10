import Foundation
@testable import NovelCore
import XCTest

/// 竖向边距默认值迁移（`VerticalInsetDefaultMigration`）的锚点测试。
///
/// ## 为什么值得单测
/// 迁移的失效模式很严重：标记逻辑写歪 ⇒ **每次启动都覆盖用户自己拖过的滑杆值**，
/// 用户永远调不回来，而且极难归因（表现出来只是「设置不生效」）。
/// 所以这里锁住四件事：只重置上下 inset、其它字段逐值不变、标记已存在时不覆盖、连续 apply 幂等。
///
/// ## 隔离
/// 一律用独立 suite 的 `UserDefaults`（`UserDefaults(suiteName:)`），`tearDown` 里清干净 ——
/// **绝不碰 `.standard`**：那是真机 / 模拟器上用户的真实阅读设置。
final class ReadingSettingsStoreTests: XCTestCase {
    /// 本用例建过的 suite 名，`tearDown` 统一清掉。
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    /// 隔离的 `UserDefaults`：独立 suite + 建时先清一次（防同进程上一次的残留）。
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "NovelCoreTests.readingSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        suiteNames.append(suiteName)
        return defaults
    }

    /// 一份「用户存过的」设置：**每个字段都刻意取非默认值**，
    /// 这样任何「顺手把别的字段也改了」的迁移都会被整结构比对抓住。
    private func makeStoredSettings(
        inset: PageInset = PageInset(top: 12, leading: 8, bottom: 0, trailing: 40)
    ) -> ReadingSettings {
        ReadingSettings(
            fontSize: 21,
            lineSpacing: 9,
            paragraphSpacing: 13,
            characterSpacing: 1.5,
            fontName: "PingFangSC-Regular",
            isBold: true,
            isItalic: true,
            firstLineHeadIndent: 24,
            inset: inset,
            backgroundStyle: .custom,
            customBackgroundColor: ReadingColor(red: 0.1, green: 0.2, blue: 0.3),
            customBackgroundColorDark: ReadingColor(red: 0.4, green: 0.5, blue: 0.6),
            textColorMode: .custom,
            customTextColor: ReadingColor(red: 0.7, green: 0.8, blue: 0.9),
            followsSystemBrightness: false,
            pageTurnMode: .slide,
            pageTurnAnimation: .none,
            appearanceMode: .dark,
            precacheCount: 7
        )
    }

    /// ① 标记不存在 + 有已存设置 ⇒ 只把**上下** inset 重置为新默认，其它字段逐值不变，标记写入。
    ///
    /// 锁的失效模式：迁移顺手改了字号 / 行距 / 颜色 / 字体 / 左右边距（用户会看到设置「自己变了」）。
    func test标记不存在时只重置上下边距并写入标记() throws {
        let defaults = try makeIsolatedDefaults()
        let stored = makeStoredSettings()

        let migrated = try XCTUnwrap(
            VerticalInsetDefaultMigration.apply(to: stored, defaults: defaults)
        )

        XCTAssertEqual(migrated.inset.top, PageInset().top)
        XCTAssertEqual(migrated.inset.bottom, PageInset().bottom)
        // 整结构比对：副本只改那两个字段 ⇒ 任何别的字段被顺手改掉都会在这里失败。
        var expected = stored
        expected.inset.top = PageInset().top
        expected.inset.bottom = PageInset().bottom
        XCTAssertEqual(migrated, expected)
        // 点名几个最容易连带出错的字段，失败时能一眼看出是哪一个漂了。
        XCTAssertEqual(migrated.inset.leading, 8)
        XCTAssertEqual(migrated.inset.trailing, 40)
        XCTAssertEqual(migrated.fontSize, 21)
        XCTAssertEqual(migrated.fontName, "PingFangSC-Regular")
        // 标记必须写入，否则下次启动会再迁移一次（把用户随后的调整又冲掉）。
        XCTAssertTrue(defaults.bool(forKey: VerticalInsetDefaultMigration.storageKey))
    }

    /// ② 标记已存在 ⇒ 用户已存的 inset **原样保留**（不重置）。
    ///
    /// 这是防「每次启动都覆盖用户自己拖过的滑杆值」的核心用例。
    func test标记已存在时原样保留用户边距() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: VerticalInsetDefaultMigration.storageKey)
        let stored = makeStoredSettings()

        let result = try XCTUnwrap(
            VerticalInsetDefaultMigration.apply(to: stored, defaults: defaults)
        )

        XCTAssertEqual(result, stored)
        XCTAssertEqual(result.inset.top, 12)
        XCTAssertEqual(result.inset.bottom, 0)
    }

    /// ③ 标记不存在 + 本机没有已存设置 ⇒ 返回 nil（不落盘），但标记仍要写入。
    ///
    /// 标记必须写：否则「首次安装 → 用户当轮把滑杆调回正值 → 下次启动」会被当成旧默认覆盖掉。
    func test标记不存在且没有已存设置时返回空并写入标记() throws {
        let defaults = try makeIsolatedDefaults()

        XCTAssertNil(VerticalInsetDefaultMigration.apply(to: nil, defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: VerticalInsetDefaultMigration.storageKey))
    }

    /// ④ 幂等：同一份已存设置连续 `apply` 两次 ⇒ 第二次逐值不变。
    ///
    /// 再加一段更贴近真机的序列：迁移过一轮之后**用户自己把滑杆拖到 +20**
    /// （上下同值，与 `ReaderSettingsView` 的滑杆行为一致），下次启动不得被重新迁移冲掉。
    func test迁移幂等且不覆盖用户后来调过的边距() throws {
        let defaults = try makeIsolatedDefaults()
        let stored = makeStoredSettings()

        let first = try XCTUnwrap(
            VerticalInsetDefaultMigration.apply(to: stored, defaults: defaults)
        )
        let second = try XCTUnwrap(
            VerticalInsetDefaultMigration.apply(to: first, defaults: defaults)
        )
        XCTAssertEqual(second, first)

        var userEdited = first
        userEdited.inset.top = 20
        userEdited.inset.bottom = 20
        let third = try XCTUnwrap(
            VerticalInsetDefaultMigration.apply(to: userEdited, defaults: defaults)
        )
        XCTAssertEqual(third, userEdited)
        XCTAssertEqual(third.inset.top, 20)
        XCTAssertEqual(third.inset.bottom, 20)
    }
}
