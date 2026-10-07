import NovelCore
import UIKit

/// 按阅读配置构建真实字体。
///
/// 分页度量与页面渲染必须使用同一套字体解析规则，否则「分页能放下」
/// 与「显示放不下」会不一致。把规则集中在这里，两端共用。
public enum ReadingFontFactory {
    /// 解析字体名并应用粗体 / 斜体。
    ///
    /// 字体名可能是 family name（例如从 `UIFont.familyNames` 选出来的值），
    /// 也可能已经是 PostScript name；两种都尝试，最后回退系统字体。
    public static func makeFont(configuration: PaginationConfiguration) -> UIFont {
        let baseFont = resolveBaseFont(configuration: configuration)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if configuration.isBold {
            traits.insert(.traitBold)
        }
        if configuration.isItalic {
            traits.insert(.traitItalic)
        }
        guard !traits.isEmpty,
              let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        else {
            return baseFont
        }
        return UIFont(descriptor: descriptor, size: configuration.fontSize)
    }

    private static func resolveBaseFont(configuration: PaginationConfiguration) -> UIFont {
        let size = configuration.fontSize
        guard let fontName = configuration.fontName, !fontName.isEmpty else {
            return UIFont.systemFont(ofSize: size)
        }
        if let font = UIFont(name: fontName, size: size) {
            return font
        }
        if let postScriptName = UIFont.fontNames(forFamilyName: fontName).first,
           let font = UIFont(name: postScriptName, size: size)
        {
            return font
        }
        return UIFont.systemFont(ofSize: size)
    }
}
