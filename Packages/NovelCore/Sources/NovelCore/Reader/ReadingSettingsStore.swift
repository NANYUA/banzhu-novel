import CoreGraphics
import Dependencies
import Foundation

/// 阅读设置的持久化快照（不含容器尺寸）。
///
/// `PaginationConfiguration.containerSize` 由页面布局实时决定，不该落盘；
/// 其余设置字段与预缓存章数一起保存，下次打开阅读页时原样恢复。
///
/// ## ⚠️ 新增字段一律声明为 `Optional`
/// `ReadingSettings` 是**整份**落盘的（`reader.settings.v1`）。合成的 `Decodable`
/// 对**缺失的 key 会抛错**（不会回退到属性默认值），而 `ReadingSettingsLive.load()`
/// 用 `try?` 吞掉错误 ⇒ 给这个类型加一个**非 Optional** 字段，会让老版本存的整份设置
/// **解不出来**、用户所有设置静默归零（字号 / 颜色 / 字体全没）。
/// 所以新增字段一律 `Optional`：`nil` 的语义是「老数据里没有这个字段」，
/// 由 `mergedConfiguration(containerSize:)` 按各自的新默认值兜底。
public struct ReadingSettings: Equatable, Sendable, Codable {
    public var fontSize: CGFloat
    public var lineSpacing: CGFloat
    public var paragraphSpacing: CGFloat
    public var characterSpacing: CGFloat
    public var fontName: String?
    public var isBold: Bool
    public var isItalic: Bool
    /// 首行缩进开关。`nil` = 老数据里没有这个 key（**不是**「关掉」）⇒ 按 owner 口径当「打开」；
    /// `false` = 用户主动关掉。缩进宽度不落盘，由 `fontSize × 2` 派生。
    public var isFirstLineIndentOn: Bool?
    public var inset: PageInset
    /// 角落标签距屏幕左右边缘的距离。`nil` = 老数据里没有这个 key ⇒ 按 `16`（= `Spacing.md`）。
    public var hudHorizontalInset: CGFloat?
    /// 上栏面板上边缘距屏幕顶的距离（绝对值语义，`0` = 贴屏幕最边缘）。
    /// `nil` = **自动**（跟随安全区，由 App 层解析）—— 老数据里没有这个 key 也落在这里，
    /// 而「自动」正是改造前的行为 ⇒ **不需要迁移 key**。
    public var topBarInset: CGFloat?
    /// 下栏面板下边缘距屏幕底的距离（绝对值语义）。`nil` = 老数据里没有这个 key ⇒ 按 `8`（= `Spacing.xs`）。
    public var bottomBarInset: CGFloat?
    /// 是否在阅读页上叠一层「书籍正文边框标识」（正文盒四周的红色虚线）。
    /// `nil` = 老数据里没有这个 key（**不是**「关掉」）⇒ 按新默认 `false`（默认不显示）。
    public var showsTextAreaBorder: Bool?
    public var backgroundStyle: ReadingBackgroundStyle
    public var customBackgroundColor: ReadingColor
    public var customBackgroundColorDark: ReadingColor
    public var textColorMode: ReadingTextColorMode
    public var customTextColor: ReadingColor
    public var followsSystemBrightness: Bool
    public var pageTurnMode: PageTurnMode
    public var pageTurnAnimation: PageTurnAnimation
    public var appearanceMode: ReadingAppearanceMode
    public var precacheCount: Int

    public init(
        fontSize: CGFloat = 17,
        lineSpacing: CGFloat = 4,
        paragraphSpacing: CGFloat = 6,
        characterSpacing: CGFloat = 0,
        fontName: String? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isFirstLineIndentOn: Bool? = true,
        inset: PageInset = PageInset(),
        hudHorizontalInset: CGFloat? = 16,
        topBarInset: CGFloat? = nil,
        bottomBarInset: CGFloat? = 8,
        showsTextAreaBorder: Bool? = false,
        backgroundStyle: ReadingBackgroundStyle = .white,
        customBackgroundColor: ReadingColor = .defaultCustomBackground,
        customBackgroundColorDark: ReadingColor = .defaultCustomBackground,
        textColorMode: ReadingTextColorMode = .automatic,
        customTextColor: ReadingColor = .defaultCustomText,
        followsSystemBrightness: Bool = true,
        pageTurnMode: PageTurnMode = .slide,
        pageTurnAnimation: PageTurnAnimation = .none,
        appearanceMode: ReadingAppearanceMode = .system,
        precacheCount: Int = ReaderFeature.defaultPrecacheCount
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.characterSpacing = characterSpacing
        self.fontName = fontName
        self.isBold = isBold
        self.isItalic = isItalic
        self.isFirstLineIndentOn = isFirstLineIndentOn
        self.inset = inset
        self.hudHorizontalInset = hudHorizontalInset
        self.topBarInset = topBarInset
        self.bottomBarInset = bottomBarInset
        self.showsTextAreaBorder = showsTextAreaBorder
        self.backgroundStyle = backgroundStyle
        self.customBackgroundColor = customBackgroundColor
        self.customBackgroundColorDark = customBackgroundColorDark
        self.textColorMode = textColorMode
        self.customTextColor = customTextColor
        self.followsSystemBrightness = followsSystemBrightness
        self.pageTurnMode = pageTurnMode
        self.pageTurnAnimation = pageTurnAnimation
        self.appearanceMode = appearanceMode
        self.precacheCount = precacheCount
    }

    public init(configuration: PaginationConfiguration, precacheCount: Int) {
        self.init(
            fontSize: configuration.fontSize,
            lineSpacing: configuration.lineSpacing,
            paragraphSpacing: configuration.paragraphSpacing,
            characterSpacing: configuration.characterSpacing,
            fontName: configuration.fontName,
            isBold: configuration.isBold,
            isItalic: configuration.isItalic,
            isFirstLineIndentOn: configuration.isFirstLineIndentOn,
            inset: configuration.inset,
            hudHorizontalInset: configuration.hudHorizontalInset,
            topBarInset: configuration.topBarInset,
            bottomBarInset: configuration.bottomBarInset,
            showsTextAreaBorder: configuration.showsTextAreaBorder,
            backgroundStyle: configuration.backgroundStyle,
            customBackgroundColor: configuration.customBackgroundColor,
            customBackgroundColorDark: configuration.customBackgroundColorDark,
            textColorMode: configuration.textColorMode,
            customTextColor: configuration.customTextColor,
            followsSystemBrightness: configuration.followsSystemBrightness,
            pageTurnMode: configuration.pageTurnMode,
            pageTurnAnimation: configuration.pageTurnAnimation,
            appearanceMode: configuration.appearanceMode,
            precacheCount: precacheCount
        )
    }

    /// 用当前页面容器尺寸合并出完整分页配置。
    ///
    /// 新增的 `Optional` 字段在这里按新默认兜底（老数据里没有它们的 key，见类型注释）：
    /// 首行缩进 `nil` ⇒ **打开**（owner 口径），标签边距 `nil` ⇒ `16`，边框开关 `nil` ⇒ **关**。
    public func mergedConfiguration(containerSize: CGSize) -> PaginationConfiguration {
        PaginationConfiguration(
            containerSize: containerSize,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            inset: inset,
            fontName: fontName,
            paragraphSpacing: paragraphSpacing,
            characterSpacing: characterSpacing,
            isBold: isBold,
            isItalic: isItalic,
            // `nil` = 老数据里没有这个 key ⇒ 打开（**不是**「关掉」）。
            isFirstLineIndentOn: isFirstLineIndentOn ?? true,
            backgroundStyle: backgroundStyle,
            customBackgroundColor: customBackgroundColor,
            customBackgroundColorDark: customBackgroundColorDark,
            textColorMode: textColorMode,
            customTextColor: customTextColor,
            followsSystemBrightness: followsSystemBrightness,
            pageTurnMode: pageTurnMode,
            pageTurnAnimation: pageTurnAnimation,
            appearanceMode: appearanceMode,
            // `nil` = 老数据里没有这个 key ⇒ 16（= `DesignTokens.Spacing.md`，与改造前的硬编码同值）。
            hudHorizontalInset: hudHorizontalInset ?? 16,
            // `nil` = 老数据里没有这个 key，**也** = 用户选了「自动」⇒ 原样传 nil，由 App 层按安全区解析。
            topBarInset: topBarInset,
            // `nil` = 老数据里没有这个 key ⇒ 8（= `DesignTokens.Spacing.xs`，与改造前的固定值同值）。
            bottomBarInset: bottomBarInset ?? 8,
            // `nil` = 老数据里没有这个 key ⇒ `false`（默认不显示边框；老版本本来就没有这个功能）。
            showsTextAreaBorder: showsTextAreaBorder ?? false
        )
    }
}

/// 阅读设置读写依赖。
///
/// 与其它 IO 依赖同理：reducer 不直接碰 `UserDefaults`，
/// 测试用 `withDependencies` 换成内存桩，断言的仍是完整状态迁移。
struct ReadingSettingsStore: Sendable {
    var load: @Sendable () -> ReadingSettings?
    var save: @Sendable (ReadingSettings) -> Void
}

extension DependencyValues {
    var readingSettingsStore: ReadingSettingsStore {
        get { self[ReadingSettingsStoreKey.self] }
        set { self[ReadingSettingsStoreKey.self] = newValue }
    }

    private enum ReadingSettingsStoreKey: DependencyKey {
        static let liveValue = ReadingSettingsStore(
            load: { ReadingSettingsLive.load() },
            save: { ReadingSettingsLive.save($0) }
        )

        /// 测试默认值：不读不写，避免忘记注入桩的测试意外污染真实设置。
        static let testValue = ReadingSettingsStore(
            load: { nil },
            save: { _ in }
        )
    }
}

private enum ReadingSettingsLive {
    private static let storageKey = "reader.settings.v1"

    static func load() -> ReadingSettings? {
        let stored = UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(ReadingSettings.self, from: $0) }
        let settings = VerticalInsetDefaultMigration.apply(to: stored)
        // 迁移真的改了值才回写（标记已存在时 `migrated == stored`，不写）。
        if let settings, let stored, settings.inset != stored.inset {
            save(settings)
        }
        return settings
    }

    static func save(_ settings: ReadingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// 竖向边距默认值的一次性迁移（U9-7；2026-10-11 语义变更后再迁移一次）。
///
/// ## 为什么需要
/// `ReadingSettings` 是**整份**落盘的（`reader.settings.v1`）⇒ 已安装的设备上存着旧默认，
/// 不改的话 `PageInset` 的新默认**永远轮不到生效**，owner 在真机上就看不到任何变化。
/// 这一次还多一层：`top/bottom` 的**语义**从「相对安全区向屏幕边缘推的偏移量（可为负）」
/// 改成了「距**屏幕边缘**的绝对距离（≥ 0）」⇒ 旧值在新语义下**无意义**
/// （`-18` 会被读成「屏幕外 18pt」），必须重置。
///
/// ## 语义（惰性写入 + 标记，写法沿用 `ContentEpoch`）
/// - 标记不存在 ⇒ 把已存的 `inset.top/bottom` 重置为新默认（`PageInset()` = 78 / 30），并写入标记；
/// - 标记存在 ⇒ 一律尊重用户已存的值（用户自己调过滑杆就不再覆盖）。
///
/// ## 边界
/// **只动上下 inset**：字号 / 行距 / 颜色 / 字体 / 翻页方式 / 左右边距等已存设置原样保留
/// —— 不清空整份设置，也不改 `reader.settings.v1` 的版本号（那会连带丢掉用户其它设置）。
/// 本机**没有**已存设置时也写标记：那种情况新默认本来就生效，标记只是防止
/// 「首次安装 → 用户当轮把滑杆调回正值 → 下次启动被当成旧默认覆盖掉」。
///
/// ⚠️ 新增的 `isFirstLineIndentOn` / `hudHorizontalInset` / `showsTextAreaBorder` **不在这里迁移**：
/// 它们是新字段，老数据里没有 key ⇒ 解码成 `nil` ⇒ 由 `mergedConfiguration(containerSize:)`
/// 按新默认兜底（缩进打开、标签边距 16、边框开关关）。
enum VerticalInsetDefaultMigration {
    /// `UserDefaults` key，沿用本项目「`<域>.<用途>.v<版本>`」的既有命名习惯。
    ///
    /// 版本号从 `v2` 提到 `v3`（2026-10-11：`PageInset.top/bottom` 的语义由
    /// 「相对安全区的偏移（可为负）」改成「距屏幕边缘的绝对距离（≥ 0）」，默认 `78 / 30`）：
    /// 这个迁移的语义是「**标记不存在** ⇒ 把已存的上下 inset 重置为新默认」，而 `v2` 标记
    /// 在装过 U9-7 那版的设备上**早已写下** ⇒ 不改 key 的话，新默认**永远不会生效**，
    /// owner 真机上会看到「没变化」，且旧负值会以「屏幕外 18pt」这种无意义读数被沿用。
    /// 换 key 等于让新默认值再迁移一次（与 `v1` → `v2` 同一条理由）。
    ///
    /// **保持 `v3`，不要再往上提**：只有 `PageInset` 的默认值 / 语义**再次**变化时才换 key，
    /// 否则会把已装过 `v3` 的用户无谓地再重置一次（用户自己调好的边距会被冲掉）。
    static let storageKey = "reader.insetDefaultMigrated.v3"

    /// 迁移已存设置；`settings == nil` 表示本机没有已存设置（返回 nil，不落盘）。
    static func apply(
        to settings: ReadingSettings?,
        defaults: UserDefaults = .standard
    ) -> ReadingSettings? {
        guard defaults.object(forKey: storageKey) == nil else { return settings }
        defaults.set(true, forKey: storageKey)

        guard var migrated = settings else { return nil }
        let newDefault = PageInset()
        migrated.inset.top = newDefault.top
        migrated.inset.bottom = newDefault.bottom
        return migrated
    }
}
