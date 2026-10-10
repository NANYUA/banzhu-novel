import CoreGraphics
import Dependencies
import Foundation

/// 阅读设置的持久化快照（不含容器尺寸）。
///
/// `PaginationConfiguration.containerSize` 由页面布局实时决定，不该落盘；
/// 其余设置字段与预缓存章数一起保存，下次打开阅读页时原样恢复。
public struct ReadingSettings: Equatable, Sendable, Codable {
    public var fontSize: CGFloat
    public var lineSpacing: CGFloat
    public var paragraphSpacing: CGFloat
    public var characterSpacing: CGFloat
    public var fontName: String?
    public var isBold: Bool
    public var isItalic: Bool
    public var firstLineHeadIndent: CGFloat
    public var inset: PageInset
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
        firstLineHeadIndent: CGFloat = 0,
        inset: PageInset = PageInset(),
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
        self.firstLineHeadIndent = firstLineHeadIndent
        self.inset = inset
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
            firstLineHeadIndent: configuration.firstLineHeadIndent,
            inset: configuration.inset,
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
            firstLineHeadIndent: firstLineHeadIndent,
            backgroundStyle: backgroundStyle,
            customBackgroundColor: customBackgroundColor,
            customBackgroundColorDark: customBackgroundColorDark,
            textColorMode: textColorMode,
            customTextColor: customTextColor,
            followsSystemBrightness: followsSystemBrightness,
            pageTurnMode: pageTurnMode,
            pageTurnAnimation: pageTurnAnimation,
            appearanceMode: appearanceMode
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

/// 竖向边距默认值的一次性迁移（U9-7）。
///
/// ## 为什么需要
/// `ReadingSettings` 是**整份**落盘的（`reader.settings.v1`）⇒ 已安装的设备上存着旧默认
/// `inset.top/bottom = 0`，不改的话 `PageInset` 的新默认**永远轮不到生效**，
/// owner 在真机上就看不到任何变化。
///
/// ## 语义（惰性写入 + 标记，写法沿用 `ContentEpoch`）
/// - 标记不存在 ⇒ 把已存的 `inset.top/bottom` 重置为新默认（`PageInset()`），并写入标记；
/// - 标记存在 ⇒ 一律尊重用户已存的值（用户自己调过滑杆就不再覆盖）。
///
/// ## 边界
/// **只动上下 inset**：字号 / 行距 / 颜色 / 字体 / 翻页方式等已存设置原样保留
/// —— 不清空整份设置，也不改 `reader.settings.v1` 的版本号（那会连带丢掉用户其它设置）。
/// 本机**没有**已存设置时也写标记：那种情况新默认本来就生效，标记只是防止
/// 「首次安装 → 用户当轮把滑杆调回正值 → 下次启动被当成旧默认覆盖掉」。
enum VerticalInsetDefaultMigration {
    /// `UserDefaults` key，沿用本项目「`<域>.<用途>.v<版本>`」的既有命名习惯。
    static let storageKey = "reader.insetDefaultMigrated.v1"

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
