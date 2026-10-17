import CoreGraphics
import NovelCore
import XCTest

/// 香色闺阁排版参数移植后的**纯逻辑**守护（不依赖 UIKit，CI 会跑）。
///
/// 对应参数表：香色闺阁 `resources/plist_paibanKeyInfo.plist` + `plist_localConfig.plist`
/// 的 `rmd_paibanListV2`。这里只锁「派生规则 / 兜底规则 / 重排判定 / 老数据解码」，
/// 属性的真实渲染由 `Packages/NovelPagination` 的 `ReadingTextAttributes` 负责（CI 只编译不测）。
final class TypesettingParameterTests: XCTestCase {
    // MARK: - 首行缩进：按「字」算

    /// 缩进宽度 = 字数 × 字号（香色闺阁的 `headIndent` 单位就是字，不是 pt）。
    func test首行缩进按字数乘字号派生() {
        let configuration = PaginationConfiguration(
            containerSize: CGSize(width: 320, height: 480),
            fontSize: 20,
            isFirstLineIndentOn: true,
            firstLineIndentChars: 3
        )

        XCTAssertEqual(configuration.firstLineHeadIndent, 60)
    }

    /// 老开关仍然有一票否决权（老数据 / 老调用点靠它表达「不缩进」）。
    func test缩进开关关掉时字数为零宽度() {
        let configuration = PaginationConfiguration(
            containerSize: CGSize(width: 320, height: 480),
            fontSize: 20,
            isFirstLineIndentOn: false,
            firstLineIndentChars: 3
        )

        XCTAssertEqual(configuration.firstLineHeadIndent, 0)
    }

    /// 老数据没有「字数」这个 key：开着 ⇒ 2 字（= 旧实现固定 2 字），关着 ⇒ 0 字。
    func test老数据没有字数时按开关回落() {
        var legacyOn = ReadingSettings()
        legacyOn.isFirstLineIndentOn = nil
        legacyOn.firstLineIndentChars = nil
        XCTAssertEqual(legacyOn.resolvedFirstLineIndentChars, 2)

        var legacyOff = ReadingSettings()
        legacyOff.isFirstLineIndentOn = false
        legacyOff.firstLineIndentChars = nil
        XCTAssertEqual(legacyOff.resolvedFirstLineIndentChars, 0)

        // 算出来的宽度与旧实现逐值一致（`fontSize × 2`）。
        let merged = legacyOn.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))
        XCTAssertEqual(merged.firstLineHeadIndent, legacyOn.fontSize * 2)
    }

    /// 新 key 越界要夹到 `0 … 5`（滑杆只给 0…5，但老 JSON / 手改都能塞进任意值）。
    func test字数越界被夹进零到五() {
        var settings = ReadingSettings()
        settings.firstLineIndentChars = 9
        XCTAssertEqual(settings.resolvedFirstLineIndentChars, 5)

        settings.firstLineIndentChars = -3
        XCTAssertEqual(settings.resolvedFirstLineIndentChars, 0)
    }

    // MARK: - 标题参数：nil 跟随正文

    func test标题参数为空时跟随正文() {
        let configuration = PaginationConfiguration(
            containerSize: CGSize(width: 320, height: 480),
            fontSize: 17,
            lineSpacing: 8,
            paragraphSpacing: 12,
            characterSpacing: 1,
            titleFontSizeOffset: 3,
            titleCharacterSpacing: nil,
            titleLineSpacing: nil,
            titleParagraphSpacing: nil
        )

        XCTAssertEqual(configuration.resolvedTitleFontSize, 20)
        XCTAssertEqual(configuration.resolvedTitleCharacterSpacing, 1)
        XCTAssertEqual(configuration.resolvedTitleLineSpacing, 8)
        XCTAssertEqual(configuration.resolvedTitleParagraphSpacing, 12)
    }

    func test标题参数显式值优先于正文() {
        let configuration = PaginationConfiguration(
            containerSize: CGSize(width: 320, height: 480),
            lineSpacing: 8,
            paragraphSpacing: 12,
            characterSpacing: 1,
            titleCharacterSpacing: 2,
            titleLineSpacing: 9,
            titleParagraphSpacing: 13
        )

        XCTAssertEqual(configuration.resolvedTitleCharacterSpacing, 2)
        XCTAssertEqual(configuration.resolvedTitleLineSpacing, 9)
        XCTAssertEqual(configuration.resolvedTitleParagraphSpacing, 13)
    }

    // MARK: - 重排判定

    /// 新参数都属于「排版输入」：改任何一个都必须触发重新分页，否则正文会按旧盒排、显示错位。
    func test新增排版参数都会触发重新分页() {
        let base = PaginationConfiguration(containerSize: CGSize(width: 320, height: 480))

        var indent = base
        indent.firstLineIndentChars = 1
        XCTAssertTrue(indent.affectsPagination(comparedTo: base))

        var weight = base
        weight.fontWeight = 4
        XCTAssertTrue(weight.affectsPagination(comparedTo: base))

        var titleSize = base
        titleSize.titleFontSizeOffset = 5
        XCTAssertTrue(titleSize.affectsPagination(comparedTo: base))

        var titleWeight = base
        titleWeight.titleFontWeight = -2
        XCTAssertTrue(titleWeight.affectsPagination(comparedTo: base))

        var titleSpacing = base
        titleSpacing.titleLineSpacing = 20
        XCTAssertTrue(titleSpacing.affectsPagination(comparedTo: base))
    }

    /// 反例：只改「纯渲染」的字段不该重排（否则拖一下标签边距就重排整章）。
    func test只改渲染字段不触发重新分页() {
        let base = PaginationConfiguration(containerSize: CGSize(width: 320, height: 480))

        var hud = base
        hud.hudHorizontalInset = 40
        XCTAssertFalse(hud.affectsPagination(comparedTo: base))

        var border = base
        border.showsTextAreaBorder = true
        XCTAssertFalse(border.affectsPagination(comparedTo: base))
    }

    // MARK: - 老数据解码

    /// 新增的 7 个字段必须都是 `Optional`：老 JSON 缺这些 key 时仍能解码，
    /// 解出来的值是 `nil`（语义 = 「老数据里没有」），而不是抛错。
    func test缺少新增字段的老JSON仍可解码() throws {
        let data = try JSONEncoder().encode(ReadingSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let removedKeys = [
            "firstLineIndentChars",
            "fontWeight",
            "titleFontSizeOffset",
            "titleFontWeight",
            "titleCharacterSpacing",
            "titleLineSpacing",
            "titleParagraphSpacing",
        ]
        for key in removedKeys {
            object[key] = nil
        }
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ReadingSettings.self, from: legacy)

        XCTAssertNil(decoded.firstLineIndentChars)
        XCTAssertNil(decoded.fontWeight)
        XCTAssertNil(decoded.titleFontSizeOffset)
        XCTAssertNil(decoded.titleFontWeight)
        XCTAssertNil(decoded.titleCharacterSpacing)
        XCTAssertNil(decoded.titleLineSpacing)
        XCTAssertNil(decoded.titleParagraphSpacing)

        // 兜底后再进配置：字重 0、标题增量 1、标题字重 3（= 香色闺阁「默认排版」一套）。
        let merged = decoded.mergedConfiguration(containerSize: CGSize(width: 320, height: 480))
        XCTAssertEqual(merged.fontWeight, 0)
        XCTAssertEqual(merged.titleFontSizeOffset, 1)
        XCTAssertEqual(merged.titleFontWeight, 3)
    }
}
