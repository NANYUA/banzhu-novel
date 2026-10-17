import Foundation
@testable import NovelCore
import XCTest

/// 编码探测测试。
///
/// 🔴 关键口径：本地 txt 必须是 **UTF-8 优先**，不能复用 `NovelEngine.GBK.decode`
/// 的「先 GB18030 再 UTF-8」—— 后者会把 UTF-8 中文静默解成乱码且不报错。
final class TextDecoderTests: XCTestCase {
    func testUTF8无BOM_原样解码() throws {
        let text = "第一章 起点\n正文一"
        let data = try XCTUnwrap(text.data(using: .utf8))
        XCTAssertEqual(try TextDecoder.decode(data), text)
    }

    /// UTF-8 带 BOM（Windows 记事本常见）：BOM 必须被剥掉，否则第一章标题首字符是 U+FEFF，
    /// 正则 `^` 对不上，标题会被吞进正文。
    func testUTF8带BOM_剥掉BOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        try data.append(XCTUnwrap("第一章 起点".data(using: .utf8)))
        let decoded = try TextDecoder.decode(data)
        XCTAssertEqual(decoded, "第一章 起点")
        XCTAssertFalse(decoded.hasPrefix("\u{FEFF}"))
    }

    func testUTF16LE带BOM_能解码() throws {
        var data = Data([0xFF, 0xFE])
        try data.append(XCTUnwrap("第一章 起点".data(using: .utf16LittleEndian)))
        XCTAssertEqual(try TextDecoder.decode(data), "第一章 起点")
    }

    /// GBK 字节（「第1章」= B5 DA 31 D5 C2）：不是合法 UTF-8，才退到 GB18030。
    func testGBK字节_退到GB18030() throws {
        let data = Data([0xB5, 0xDA, 0x31, 0xD5, 0xC2])
        XCTAssertNil(String(data: data, encoding: .utf8), "前提：这段字节不是合法 UTF-8")
        XCTAssertEqual(try TextDecoder.decode(data), "第1章")
    }

    func test空文件_报空文件() {
        XCTAssertThrowsError(try TextDecoder.decode(Data(), fileName: "空.txt")) { error in
            XCTAssertEqual(error as? TextDecoder.DecodingError, .empty(fileName: "空.txt"))
        }
    }

    func test无法识别的字节_报编码不支持() {
        let data = Data([0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try TextDecoder.decode(data, fileName: "怪.txt")) { error in
            XCTAssertEqual(error as? TextDecoder.DecodingError, .unsupported(fileName: "怪.txt"))
        }
    }

    func test错误文案带书名() {
        XCTAssertEqual(
            TextDecoder.DecodingError.empty(fileName: "空.txt").errorDescription,
            "《空.txt》是空文件。"
        )
        XCTAssertEqual(
            TextDecoder.DecodingError.unsupported(fileName: "怪.txt").errorDescription,
            "《怪.txt》的编码无法识别（支持 UTF-8 / UTF-16 / GBK / GB18030）。"
        )
    }
}
