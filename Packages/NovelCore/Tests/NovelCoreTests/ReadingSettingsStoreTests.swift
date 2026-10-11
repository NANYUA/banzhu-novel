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
/// 2026-10-11（竖向边距语义变更）追加两组锚点：
/// - 迁移标记必须换到 `v3` —— 否则装过 U9-7 那版的设备上，新默认（78 / 30）永远不会生效；
/// - 两个新字段（首行缩进开关 / 标签边距）的**老数据兼容**：缺 key 的旧 JSON 仍能解码
///   （新字段一律 `Optional` 的原因），且 `nil` 由 `mergedConfiguration` 按新默认兜底。
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
            isFirstLineIndentOn: false,
            inset: inset,
            hudHorizontalInset: 40,
            topBarInset: 40,
            bottomBarInset: 0,
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
        // 新增的两个字段同样逐值保留（显式关掉的缩进不能被强行打开）。
        XCTAssertEqual(migrated.isFirstLineIndentOn, false)
        XCTAssertEqual(migrated.hudHorizontalInset, 40)
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

    // MARK: - 2026-10-11：竖向边距语义变更 + 两个新字段

    /// ⑤ 老版本存下的 JSON（**没有**新增的两个 key）必须仍能解出来。
    ///
    /// 锁的失效模式：给 `ReadingSettings` 加一个**非 Optional** 字段 ⇒ 合成 `Decodable`
    /// 对缺失的 key 抛错 ⇒ `ReadingSettingsLive.load()` 的 `try?` 把它吞成 `nil`
    /// ⇒ 用户**整份**设置静默归零（字号 / 颜色 / 字体全没）。这正是新字段一律 `Optional` 的原因。
    func test缺少新增字段的旧数据仍可解码() throws {
        let data = try JSONEncoder().encode(makeStoredSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // 老版本的 JSON 里没有这几个 key（下标赋 nil = 删掉这个 key）。
        object["isFirstLineIndentOn"] = nil
        object["hudHorizontalInset"] = nil
        object["topBarInset"] = nil
        object["bottomBarInset"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ReadingSettings.self, from: legacy)

        XCTAssertNil(decoded.isFirstLineIndentOn)
        XCTAssertNil(decoded.hudHorizontalInset)
        XCTAssertNil(decoded.topBarInset)
        XCTAssertNil(decoded.bottomBarInset)
        // 老数据的其它字段逐值保留（解码本身不得动它们）。
        XCTAssertEqual(decoded.fontSize, 21)
        XCTAssertEqual(decoded.inset, PageInset(top: 12, leading: 8, bottom: 0, trailing: 40))
        XCTAssertEqual(decoded.backgroundStyle, .custom)
    }

    /// ⑥ 老数据（四个新字段都是 `nil`）经 `mergedConfiguration` 兜底：
    /// 首行缩进**打开**（owner 口径「默认打开」）、标签边距 `16`（= `Spacing.md`）、
    /// 上栏边距**保持 `nil`**（= 自动，由 App 层按安全区解析）、下栏边距 `8`（= `Spacing.xs`）。
    func test老数据的新字段按新默认兜底() {
        var legacy = ReadingSettings()
        legacy.isFirstLineIndentOn = nil
        legacy.hudHorizontalInset = nil
        legacy.topBarInset = nil
        legacy.bottomBarInset = nil

        let merged = legacy.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))

        XCTAssertTrue(merged.isFirstLineIndentOn)
        XCTAssertEqual(merged.firstLineHeadIndent, legacy.fontSize * 2)
        XCTAssertEqual(merged.hudHorizontalInset, 16)
        // ⚠️ `nil` 不等于「0」：它是「自动」，所以这里**必须**仍是 nil。
        XCTAssertNil(merged.topBarInset)
        XCTAssertEqual(merged.bottomBarInset, 8)
    }

    /// ⑦ 用户主动关掉缩进 / 改过标签边距 / 拖过上下栏边距之后，合并结果必须是**存下来的值**
    /// （不能被默认兜底盖掉 —— 那会让「设置改不动」）。
    func test已存的新字段优先于默认兜底() {
        var stored = ReadingSettings()
        stored.isFirstLineIndentOn = false
        stored.hudHorizontalInset = 48
        stored.topBarInset = 40
        stored.bottomBarInset = 0

        let merged = stored.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))

        XCTAssertFalse(merged.isFirstLineIndentOn)
        XCTAssertEqual(merged.firstLineHeadIndent, 0)
        XCTAssertEqual(merged.hudHorizontalInset, 48)
        XCTAssertEqual(merged.topBarInset, 40)
        // `0` 是**有效值**（贴屏幕最边缘），不能被 `?? 8` 兜底吃掉。
        XCTAssertEqual(merged.bottomBarInset, 0)
    }

    /// ⑧ 两处默认值同源（写法沿用 `PaginatorTests` ⑰）：`ReadingSettings()` 与
    /// `PaginationConfiguration` 的标签边距 / 缩进开关 / 上下栏边距必须一致 ——
    /// 漂了就会出现「从没动过设置，但阅读页与设置页读数不同」。
    func test新字段的两处默认值同源() {
        let settings = ReadingSettings()
        let configuration = PaginationConfiguration(containerSize: CGSize(width: 320, height: 480))

        XCTAssertEqual(settings.hudHorizontalInset, configuration.hudHorizontalInset)
        XCTAssertEqual(settings.isFirstLineIndentOn, configuration.isFirstLineIndentOn)
        XCTAssertEqual(settings.topBarInset, configuration.topBarInset)
        XCTAssertEqual(settings.bottomBarInset, configuration.bottomBarInset)
        XCTAssertEqual(configuration.hudHorizontalInset, 16)
        XCTAssertTrue(configuration.isFirstLineIndentOn)
        // ⚠️ 上栏默认是 `nil`（自动）—— 不是某个具体数字；下栏默认 8。
        XCTAssertNil(configuration.topBarInset)
        XCTAssertEqual(configuration.bottomBarInset, 8)
        // 缩进宽度由开关与字号派生（不单独落盘）。
        XCTAssertEqual(configuration.firstLineHeadIndent, configuration.fontSize * 2)
    }

    /// ⑨ 迁移标记必须是 `v3`。
    ///
    /// 锁的失效模式：这个迁移的语义是「**标记不存在** ⇒ 重置为新默认」，而 `v2` 标记在装过
    /// U9-7 那版的设备上**早已写下** ⇒ 谁把 key 改回 `v2`，那些设备的新默认（78 / 30）
    /// **永远不会生效**，owner 真机上只会看到「没变化」。
    func test迁移标记为第三版() {
        XCTAssertEqual(VerticalInsetDefaultMigration.storageKey, "reader.insetDefaultMigrated.v3")
    }
}
