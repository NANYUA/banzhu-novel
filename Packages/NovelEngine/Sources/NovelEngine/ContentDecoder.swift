import Foundation

/// 正文解码器 —— 移植自已验证的 prototype/mumu_decode.py
/// 原理：正文里敏感字被写成 <img src="/toimg/data/<编号>.png">，
///       先还原成 #编号#，再按映射表换成汉字，最后跑净化/排版正则。
enum ContentDecoder {
    // MARK: - ① 编号 -> 汉字 映射表（约 140 字，与 Python 版一致）
    private static let mapText = """
    1040782805 奸
    1063785572 搞
    1082275499 台
    1218400718 虐
    1697595086 斩
    1801354585 勃
    1810002091 九
    1947937898 粉
    2022721869 粉
    2033008053 撸
    2063259833 色
    2090369734 熟
    2173857009 高
    2174754224 暴
    2276251664 嫩
    2293535402 兽
    2444947917 性
    2471389451 湿
    2525826615 狗
    2548022544 狗
    2553168545 穴
    2633701054 棒
    2761875847 胸
    2769203094 未
    2781961287 厥
    2811411890 亡
    2965616717 爱
    3043454467 日
    3089649511 宫
    3296363576 欲
    3309926634 宰
    3342690501 舌
    3382216428 义
    3746262645 舔
    3893173869 介
    4006928252 吞
    4017050851 交
    0678663477 情
    5736430795 内
    5110754259 吸
    9763512263 美
    0923672614 死
    5318824731 妈
    6197424834 中
    9925956069 处
    0486110525 水
    6378369235 胡
    5732450242 母
    8087788059 国
    6259252852 杀
    6514831790 血
    7228562021 纪
    7051993783 硬
    9636759436 药
    6789528781 学
    5213317466 具
    9134848937 做
    5910985788 足
    7074467222 逼
    5265224411 干
    9860153795 麻
    4933790542 枪
    8698737337 奶
    7051410763 马
    4740869798 操
    8478694653 主
    6855685283 摇
    6281647881 流
    0423651377 插
    4808579862 臀
    5946892177 淫
    4481675898 荡
    8280163404 蛋
    9308659858 射
    0961296593 弹
    5229950952 肉
    5260398634 指
    6050660618 屁
    5969522288 亲
    5429058065 弟
    5366734122 共
    6957748176 尸
    9928120606 腿
    0551252288 龟
    7618693335 呻
    0975893408 吟
    0026372214 丝
    5318162318 贱
    0720742117 乳
    4488426878 缝
    6768988724 鸡
    0092238155 阴
    0551722925 唇
    6534003186 蜜
    5518664754 骚
    4668655063 潮
    4766000693 精
    8666880661 凌
    5105645092 温
    5329628684 辱
    0473556214 含
    4472054519 咪
    7508904751 帮
    0783213298 丁
    9821815185 裸
    0146287633 露
    0756494362 偷
    5710915044 童
    8954155954 炮
    5004143384 乱
    9829762678 妇
    4538628495 挤
    9173059916 毒
    9720548295 杜
    7130632296 席
    8993789017 洞
    5758773674 棍
    5245263419 轮
    0261725863 泽
    9572021917 尿
    8926554707 炸
    0351216125 坑
    0050897572 涛
    4436421269 党
    8997927012 灭
    8592042303 腐
    6560841485 伦
    1607055014 酸
    2158558763 幼
    8051876761 漪
    4704630913 茎
    0519063805 秽
    8861933232 婊
    8261828414 肛
    8025291368 锦
    0813524594 妓
    2729628100 颅
    4510436554 菊
    1024850854 嫡
    """

    /// 编号 -> 汉字（同时登记原串与去前导零串，容错图片文件名无前导零）
    static let code2char: [String: String] = {
        var m: [String: String] = [:]
        for line in mapText.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            let code = String(parts[0])
            let ch = String(parts[1])
            m[code] = ch
            let trimmed = String(code.drop(while: { $0 == "0" }))
            if !trimmed.isEmpty { m[trimmed] = ch }
        }
        return m
    }()

    private static let cjk = "\u{4e00}-\u{9fa5}"

    // MARK: - 正则替换辅助
    private static func sub(_ pattern: String, _ repl: String, _ s: String,
                            opts: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: repl)
    }

    /// 对应 Python 版 loop()：循环替换到不变为止
    private static func loop(_ pattern: String, _ repl: String, _ s: String,
                             opts: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        var cur = s
        for _ in 0..<200 {
            let range = NSRange(cur.startIndex..., in: cur)
            let next = re.stringByReplacingMatches(in: cur, options: [], range: range, withTemplate: repl)
            if next == cur { break }
            cur = next
        }
        return cur
    }

    // MARK: - ② 取正文容器
    static func extractBody(_ html: String) -> String {
        let selectors = [
            "<div[^>]*class=\"[^\"]*page-content[^\"]*\"[^>]*>(.*?)</div>",
            "<div[^>]*id=\"content\"[^>]*>(.*?)</div>",
            "<div[^>]*id=\"nr1\"[^>]*>(.*?)</div>"
        ]
        for sel in selectors {
            if let re = try? NSRegularExpression(pattern: sel, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let range = NSRange(html.startIndex..., in: html)
                if let m = re.firstMatch(in: html, options: [], range: range),
                   let r = Range(m.range(at: 1), in: html) {
                    return String(html[r])
                }
            }
        }
        if let re = try? NSRegularExpression(pattern: "<body[^>]*>(.*?)</body>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(html.startIndex..., in: html)
            if let m = re.firstMatch(in: html, options: [], range: range),
               let r = Range(m.range(at: 1), in: html) {
                return String(html[r])
            }
        }
        return html
    }

    // MARK: - ③ HTML -> 带 #编号# 的纯文本
    static func html2text(_ raw: String) -> String {
        var s = raw
        // <img src="/toimg/data/N.png"> -> #N#
        s = sub("<img[^>]*?/toimg/data/(\\d+)\\.png[^>]*?>", "#$1#", s, opts: [.caseInsensitive])
        // 兜底 <font data-code="N">...</font> -> #N#
        s = sub("<font[^>]*?data-code=\"(\\d+)\"[^>]*?>.*?</font>", "#$1#", s, opts: [.caseInsensitive, .dotMatchesLineSeparators])
        s = sub("<br\\s*/?>", "\n", s, opts: [.caseInsensitive])
        s = sub("</p\\s*>", "\n", s, opts: [.caseInsensitive])
        s = sub("<p[^>]*>", "", s, opts: [.caseInsensitive])
        s = sub("<[^>]+>", "", s)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return s
    }

    // MARK: - ④ #编号# -> 汉字
    static func restore(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "#(\\d{6,})#") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let code = ns.substring(with: m.range(at: 1))
            let ch = code2char[code] ?? code2char[String(code.drop(while: { $0 == "0" }))] ?? ""
            result += ch
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - ⑤ 净化 + 排版（逐条对应 Python clean()）
    static func clean(_ input: String) -> String {
        var s = input
        let i: NSRegularExpression.Options = [.caseInsensitive]

        // --- 净化：广告 / 推广行 ---
        s = sub("([^\\n]*?(手.?机.?看.?[小片](.?[书说])?|搜?.{0,4}索?.{0,4}第.{0,4}一.{0,4}版.{0,4}主)[^\\n]*)", "", s, opts: i)
        s = sub("([^\\n]*([最樶]新.?)?[地网].?[址祉阯].?[发發沷].?[布怖].?[页頁]?[\\:：]?[1１4４]?[^\\n]*)", "", s)
        s = sub("([^\\n]*使用chrome谷歌浏览[^\\n]*)", "", s, opts: i)
        s = sub("([^<\\n]*?手.机.看.小.[书说][^\\n]*)", "", s, opts: i)
        s = sub("(手机阅读小说：７７７８８７７[^\\n]*)", "", s)
        s = sub("(diyibanzhu@gmail\\.com)", "", s)
        s = sub("（苹果手机使用.+", "", s)
        s = s.replacingOccurrences(of: "www.diyibanzhu.net", with: "")

        // --- 分页断行哨兵 ---
        s = sub("([\\r\\n]?\\s*(hereispagebreak)[\\r\\n]?\\s*)", "", s, opts: i)

        // --- 35 字换行排版恢复（循环打标记）---
        s = loop("([\\r\\n])((tjjtds)?.{33,39}[，、．～…\"：；'—『「\(cjk)][\\r\\n])\\s{2}", "$1$2tjjtds", s, opts: i)

        // --- 换行修复 ---
        s = sub("[\\r\\n](tjjtds|　+?[\\r\\n])", "", s)
        s = sub("([\(cjk)])[ 　]+([\(cjk)])", "$1$2", s)
        s = sub("[\\r\\n]{2,}", "\r\n", s)
        s = loop("([「][^」]+)\\s*\\n\\s*", "$1", s)
        s = sub("([\(cjk)][『「][^，。？！：；]{1,12}[」』])\\s+", "$1", s)
        s = sub("([。！？…])([『「])", "$1\r\n　　$2", s)

        // --- 收尾：汉字间空格清理 ---
        s = sub("([\(cjk)])\\s+([\(cjk)])", "$1$2", s)
        return s
    }

    // MARK: - 主入口
    static func decode(html: String) -> String {
        return clean(restore(html2text(extractBody(html)))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
