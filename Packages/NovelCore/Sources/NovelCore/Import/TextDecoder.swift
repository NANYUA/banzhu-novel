import CoreFoundation
import Foundation

/// 本地 txt 的编码探测与解码。
///
/// ## 🔴 为什么不复用 `NovelEngine.GBK.decode`
/// 那个实现是**先试 GB18030、失败再退 UTF-8**（`GBK.swift:19-25`）——
/// 对网页响应头声明 GBK 的抓取结果没问题，对本地 txt 却是**反的**：
/// UTF-8 的中文字节一定能被 GB18030 「解出来」（只是变成乱码），
/// 于是 UTF-8 小说会被静默解成一片乱码，且**不会报错**。
///
/// 本地文件的正确顺序是：**BOM → 严格 UTF-8 → GB18030**。
/// `String(data:encoding:.utf8)` 对非法序列返回 `nil`（严格模式），这正是我们要的闸门。
///
/// ## 不支持的编码
/// 探测不出（四种都不成立）就抛 `.unsupported`，**不猜**。
/// 猜错的结果是用户看到整本乱码，比直接提示「编码无法识别」更糟。
public enum TextDecoder {
    public enum DecodingError: LocalizedError, Equatable {
        case empty(fileName: String)
        case unsupported(fileName: String)

        public var errorDescription: String? {
            switch self {
            case let .empty(fileName):
                "《\(fileName)》是空文件。"
            case let .unsupported(fileName):
                "《\(fileName)》的编码无法识别（支持 UTF-8 / UTF-16 / GBK / GB18030）。"
            }
        }
    }

    /// GB18030 对应的 `String.Encoding`。
    ///
    /// 为什么不用 `String.Encoding(rawValue:)` 里的现成常量：Foundation 没有暴露 GB18030 的
    /// `String.Encoding` 静态成员，必须走 CFString 编码值换算（与 `NovelEngine.GBK` 同一手法）。
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// 解码。`fileName` 只用于错误文案。
    public static func decode(_ data: Data, fileName: String = "") throws -> String {
        let name = fileName.isEmpty ? "文件" : fileName
        guard !data.isEmpty else { throw DecodingError.empty(fileName: name) }

        if let decoded = decodeByBOM(data) {
            return stripLeadingBOM(decoded)
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return stripLeadingBOM(decoded)
        }
        if let decoded = String(data: data, encoding: gb18030) {
            return stripLeadingBOM(decoded)
        }
        throw DecodingError.unsupported(fileName: name)
    }

    /// 按 BOM 判定并解码。没有 BOM（或 BOM 声明的编码解不出来）时返回 `nil`，交给后续顺序。
    private static func decodeByBOM(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(4))
        // 顺序要紧：UTF-32LE 的 BOM 以 UTF-16LE 的 BOM 开头，长的那条必须先判。
        if head.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        }
        if head.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        }
        if head.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if head.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if head.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    /// 去掉开头的 U+FEFF。
    ///
    /// BOM 已经在上面按字节剥掉了，这里兜的是「BOM 残留在解码结果里」的情况
    /// （例如文件里手写了一个 U+FEFF 字符）。留着它会让第一章标题的首字符变成零宽字符，
    /// 正则 `^` 匹配失败、章标题连正文一起被吞掉。
    private static func stripLeadingBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
