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
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ReadingSettings.self, from: data)
    }

    static func save(_ settings: ReadingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
