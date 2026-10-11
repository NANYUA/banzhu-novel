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
/// 2026-10-11（上下标签边距改默认值 + 删「自动」档）再追加一条：
/// 「上 / 下标签边距」的默认值从「自动（`nil`）/ 8」改成 **`0`**，范围 `-70 ... 70`
/// ⇒ 新装读 `0`、旧 JSON 缺 key 也兜 `0`、**负值经落盘往返不丢**（⑫），
/// 且 `ReadingSettings()` 与 `PaginationConfiguration` 两处默认值仍然同源（⑧ 锁的就是 `0`）。
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
            showsTextAreaBorder: true,
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
        // 边框开关（用户显式打开过）同样不能被迁移顺手改掉。
        XCTAssertEqual(migrated.showsTextAreaBorder, true)
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

    /// ⑤ 老版本存下的 JSON（**没有**新增的几个 key）必须仍能解出来。
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
        object["showsTextAreaBorder"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ReadingSettings.self, from: legacy)

        XCTAssertNil(decoded.isFirstLineIndentOn)
        XCTAssertNil(decoded.hudHorizontalInset)
        XCTAssertNil(decoded.topBarInset)
        XCTAssertNil(decoded.bottomBarInset)
        XCTAssertNil(decoded.showsTextAreaBorder)
        // 老数据的其它字段逐值保留（解码本身不得动它们）。
        XCTAssertEqual(decoded.fontSize, 21)
        XCTAssertEqual(decoded.inset, PageInset(top: 12, leading: 8, bottom: 0, trailing: 40))
        XCTAssertEqual(decoded.backgroundStyle, .custom)
    }

    /// ⑥ 老数据（几个新字段都是 `nil`）经 `mergedConfiguration` 兜底：
    /// 首行缩进**打开**（owner 口径「默认打开」）、标签边距 `16`（= `Spacing.md`）、
    /// 上 / 下标签边距都兜 **`0`**（贴屏幕最边缘 —— 「自动」档已按 owner 口径删除，
    /// `nil` 只剩「老数据里没有这个 key」这一个含义）、
    /// 正文边框标识**关**（老版本没有这个功能，默认不显示）。
    func test老数据的新字段按新默认兜底() {
        var legacy = ReadingSettings()
        legacy.isFirstLineIndentOn = nil
        legacy.hudHorizontalInset = nil
        legacy.topBarInset = nil
        legacy.bottomBarInset = nil
        legacy.showsTextAreaBorder = nil

        let merged = legacy.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))

        XCTAssertTrue(merged.isFirstLineIndentOn)
        XCTAssertEqual(merged.firstLineHeadIndent, legacy.fontSize * 2)
        XCTAssertEqual(merged.hudHorizontalInset, 16)
        // ⚠️ 旧数据缺 key ⇒ `0`（**不是** `nil`：`nil` 的「自动」语义已删，也不是 8）。
        XCTAssertEqual(merged.topBarInset, 0)
        XCTAssertEqual(merged.bottomBarInset, 0)
        // 边框开关 `nil` ⇒ `false`（**不是**「打开」）：老用户不该突然看到一圈红线。
        XCTAssertFalse(merged.showsTextAreaBorder)
    }

    /// ⑦ 用户主动关掉缩进 / 改过标签边距 / 拖过上下栏边距 / **打开过正文边框标识**之后，
    /// 合并结果必须是**存下来的值**（不能被默认兜底盖掉 —— 那会让「设置改不动」）。
    func test已存的新字段优先于默认兜底() {
        var stored = ReadingSettings()
        stored.isFirstLineIndentOn = false
        stored.hudHorizontalInset = 48
        stored.topBarInset = 40
        stored.bottomBarInset = 0
        stored.showsTextAreaBorder = true

        let merged = stored.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))

        XCTAssertFalse(merged.isFirstLineIndentOn)
        XCTAssertEqual(merged.firstLineHeadIndent, 0)
        XCTAssertEqual(merged.hudHorizontalInset, 48)
        XCTAssertEqual(merged.topBarInset, 40)
        // `0` 是**有效值**（贴屏幕最边缘），不能被 `?? 0` 当成「缺字段」换掉（⑫ 再锁负值）。
        XCTAssertEqual(merged.bottomBarInset, 0)
        // `true` 同样不能被 `?? false` 兜底吃掉（否则「开了又自己关」）。
        XCTAssertTrue(merged.showsTextAreaBorder)
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
        XCTAssertEqual(settings.showsTextAreaBorder, configuration.showsTextAreaBorder)
        XCTAssertEqual(configuration.hudHorizontalInset, 16)
        XCTAssertTrue(configuration.isFirstLineIndentOn)
        // ⚠️ 上下标签边距的默认值都必须是 `0`（贴屏幕最边缘）—— 「自动」档已删，
        // 所以这里不再有「默认是 nil」这回事；两处一旦漂开就会出现
        // 「从没动过设置，但阅读页与设置页读数不同」。
        XCTAssertEqual(configuration.topBarInset, 0)
        XCTAssertEqual(configuration.bottomBarInset, 0)
        // 边框标识默认**关**（`ReadingSettings()` 的 `false` 与配置的同源，见上一行断言）。
        XCTAssertFalse(configuration.showsTextAreaBorder)
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

    /// ⑩ 正文边框标识开关：**打开**的显式值经「落盘 → 解码 → 合并」往返后仍是**打开**。
    ///
    /// 锁的失效模式：`ReadingSettings.showsTextAreaBorder` 是 `Bool?`，一旦
    /// `mergedConfiguration` 里写成 `?? true`（或把默认值当成「老数据 = 打开」），
    /// 用户就会「明明关掉了，下次进来又出现」；反过来把 `true` 兜成 `false` 则是
    /// 「开了又自己关」。两端都在这条用例里锁住（⑪ 用 `false` 锁另一端）。
    func test正文边框开关往返后仍为打开() throws {
        var settings = ReadingSettings()
        settings.showsTextAreaBorder = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ReadingSettings.self, from: data)
        XCTAssertEqual(decoded.showsTextAreaBorder, true)

        let merged = decoded.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))
        XCTAssertTrue(merged.showsTextAreaBorder)
        // 往返不该动别的字段（整结构比对，与 ① 同一手法）。
        XCTAssertEqual(decoded, settings)
    }

    /// ⑪ 显式**关掉**的边框开关在合并后仍是关（`false` 是有效值，不是「缺字段」）。
    func test正文边框开关显式关闭后仍为关() {
        var settings = ReadingSettings()
        settings.showsTextAreaBorder = false

        let merged = settings.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))
        XCTAssertFalse(merged.showsTextAreaBorder)
    }

    /// ⑫ 新装默认值 = `0`（贴屏幕最边缘），且范围下限 `-70` **经落盘往返不丢**。
    ///
    /// 锁的失效模式（owner 口径「范围 −70…70、负值要真的能用」）：只要哪一层写了
    /// `max(0, …)` 或 `?? 8` 这类夹取，负值就会被悄悄吃成 `0` —— 设置页框里能输 `-70`，
    /// 回到阅读页面板却仍贴在屏幕边，用户只会觉得「设置没生效」。
    /// 这里锁**落盘 → 解码 → 合并**这条链路（App 层设置页的 `range` 由 ⑧ 的默认值一起锁）。
    func test上下标签边距默认为零且负值经往返不丢() throws {
        // 新装：`ReadingSettings()` = 没有任何已存数据时的默认值。
        XCTAssertEqual(ReadingSettings().topBarInset, 0)
        XCTAssertEqual(ReadingSettings().bottomBarInset, 0)

        var stored = ReadingSettings()
        stored.topBarInset = -70
        stored.bottomBarInset = -70

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(ReadingSettings.self, from: data)
        // 往返不该动别的字段（整结构比对，与 ① ⑩ 同一手法）。
        XCTAssertEqual(decoded, stored)

        let merged = decoded.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))
        XCTAssertEqual(merged.topBarInset, -70)
        XCTAssertEqual(merged.bottomBarInset, -70)
    }
}
