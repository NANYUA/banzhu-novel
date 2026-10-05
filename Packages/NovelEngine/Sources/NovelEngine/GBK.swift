import Foundation

/// GBK 编解码工具。
/// iOS 的 String 不内置 GBK，这里用 CoreFoundation 的 GB_18030_2000（兼容 GBK）实现。
enum GBK {
    private static var encoding: String.Encoding {
        let cf = CFStringEncodings.GB_18030_2000
        let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        return String.Encoding(rawValue: ns)
    }

    /// 中文 -> GBK 百分号编码（用于搜索 POST body，如 妻子 -> %C6%DE%D7%D3）
    static func percentEncode(_ s: String) -> String {
        guard let data = s.data(using: encoding) else { return s }
        return data.map { String(format: "%%%02X", $0) }.joined()
    }

    /// GBK 字节 -> String
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: encoding) { return s }
        // 兜底：UTF-8，再退 Latin1
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
