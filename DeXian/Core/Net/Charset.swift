import Foundation
import CoreFoundation

/// 字符集解码。
/// 中文书源大量使用 GBK/GB2312，URLSession 不会自动识别，
/// 需要按 HTTP 头 / HTML meta / BOM 逐级探测。
enum Charset {

    /// 常见字符集名 -> 编码
    static func encoding(named name: String) -> String.Encoding? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb-2312", "gb18030", "gb-18030", "cp936", "ms936", "x-gbk":
            return encoding(for: CFStringEncodings.GB_18030_2000)
        case "big5", "big-5", "cp950", "x-big5":
            return encoding(for: CFStringEncodings.big5)
        case "utf-16", "utf16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "ascii", "us-ascii": return .ascii
        case "shift-jis", "shiftjis", "sjis", "cp932":
            return encoding(for: CFStringEncodings.shiftJIS)
        case "euc-kr", "euckr":
            return encoding(for: CFStringEncodings.EUC_KR)
        case "windows-1252", "cp1252": return .windowsCP1252
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                return String.Encoding(rawValue: nsEncoding)
            }
            return nil
        }
    }

    /// 由 CFStringEncodings 常量构造编码
    private static func encoding(for encoding: CFStringEncodings) -> String.Encoding? {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        guard raw != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: raw)
    }

    /// 由 IANA 名称构造编码
    private static func encodingFromCF(_ name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// 从 Content-Type 头解析字符集。
    static func fromContentType(_ contentType: String?) -> String.Encoding? {
        guard let contentType else { return nil }
        let lowered = contentType.lowercased()
        guard let range = lowered.range(of: "charset=") else { return nil }
        var value = String(lowered[range.upperBound...])
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return encoding(named: value)
    }

    /// 从 HTML 前若干字节里解析 meta charset。
    static func fromHTMLMeta(_ data: Data) -> String.Encoding? {
        let prefix = data.prefix(4096)
        guard let ascii = String(data: prefix, encoding: .isoLatin1) else { return nil }
        let lowered = ascii.lowercased()

        if let range = lowered.range(of: "charset=") {
            var value = String(ascii[range.upperBound...])
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            var name = ""
            for character in value {
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    name.append(character)
                } else {
                    break
                }
            }
            if !name.isEmpty, let encoding = encoding(named: name) { return encoding }
        }
        return nil
    }

    /// BOM 检测
    static func fromBOM(_ data: Data) -> String.Encoding? {
        if data.count >= 3 {
            let bytes = [UInt8](data.prefix(3))
            if bytes == [0xEF, 0xBB, 0xBF] { return .utf8 }
        }
        if data.count >= 2 {
            let bytes = [UInt8](data.prefix(2))
            if bytes == [0xFF, 0xFE] { return .utf16LittleEndian }
            if bytes == [0xFE, 0xFF] { return .utf16BigEndian }
        }
        return nil
    }

    /// 综合解码：指定编码 > BOM > Content-Type > meta > UTF-8 > GB18030
    ///
    /// 关键点：GB18030 几乎能「成功」解码任意字节序列，
    /// 所以绝不能让它排在 UTF-8 前面——网页里只要有一个坏字节，
    /// UTF-8 解码失败后退到 GB18030，整篇正文就变成乱码。
    /// 这里先做严格的 UTF-8 校验，通过就直接用，不再往下试探。
    static func decode(_ data: Data, preferred: String.Encoding? = nil) -> String {
        if data.isEmpty { return "" }

        // BOM 是作者显式声明的，优先级最高
        if let encoding = fromBOM(data), let text = decodeStrict(data, encoding) {
            return cleanDecoded(text)
        }
        // UTF-8 严格校验优先于「服务器声明的字符集」。
        //
        // 很多站点的 Content-Type 写死 charset=gbk，正文却已经是 UTF-8，
        // 若先信声明就会把 UTF-8 字节按 GBK 解码，整篇变成「锟斤拷」式乱码。
        // 反过来（真 GBK 页面）在 UTF-8 校验里必然失败，不会误判。
        if isValidUTF8(data), let text = String(data: data, encoding: .utf8) {
            return cleanDecoded(text)
        }
        if let encoding = preferred, let text = decodeStrict(data, encoding) {
            return cleanDecoded(text)
        }
        if let encoding = fromHTMLMeta(data), let text = decodeStrict(data, encoding) {
            return cleanDecoded(text)
        }
        // 到这里才认为是传统编码：按「解码后乱码字符最少」择优
        return cleanDecoded(bestEffortDecode(data))
    }

    /// 严格解码：失败返回 nil，不做任何替换
    private static func decodeStrict(_ data: Data, _ encoding: String.Encoding) -> String? {
        String(data: data, encoding: encoding)
    }

    /// 校验整段数据是否为合法 UTF-8（含过长编码与代理区校验）
    static func isValidUTF8(_ data: Data) -> Bool {
        var index = 0
        let bytes = [UInt8](data)
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte < 0x80 { index += 1; continue }
            var length = 0
            var lower: UInt32 = 0
            var upper: UInt32 = 0
            if byte >= 0xC2, byte <= 0xDF {
                length = 1; lower = 0x80; upper = 0xBF
            } else if byte == 0xE0 {
                length = 2; lower = 0xA0; upper = 0xBF
            } else if byte >= 0xE1, byte <= 0xEC {
                length = 2; lower = 0x80; upper = 0xBF
            } else if byte == 0xED {
                length = 2; lower = 0x80; upper = 0x9F
            } else if byte >= 0xEE, byte <= 0xEF {
                length = 2; lower = 0x80; upper = 0xBF
            } else if byte == 0xF0 {
                length = 3; lower = 0x90; upper = 0xBF
            } else if byte >= 0xF1, byte <= 0xF3 {
                length = 3; lower = 0x80; upper = 0xBF
            } else if byte == 0xF4 {
                length = 3; lower = 0x80; upper = 0x8F
            } else {
                return false
            }
            guard index + length < count else { return false }
            for offset in 1...length {
                let next = bytes[index + offset]
                let lowerBound = offset == 1 ? lower : 0x80
                let upperBound = offset == 1 ? upper : 0xBF
                guard UInt32(next) >= lowerBound, UInt32(next) <= upperBound else { return false }
            }
            index += length + 1
        }
        return true
    }

    /// 在候选编码里挑「乱码最少」的那个。
    ///
    /// 判据是替换字符与私有区字符的数量：真正解码正确的编码几乎不会产生它们。
    private static func bestEffortDecode(_ data: Data) -> String {
        let candidates: [String.Encoding] = [
            encoding(named: "gb18030") ?? .utf8,
            encoding(named: "big5") ?? .utf8,
            encoding(named: "shift-jis") ?? .utf8
        ]
        var best = ""
        var bestScore = Int.max
        for candidate in candidates {
            guard let text = String(data: data, encoding: candidate) else { continue }
            let score = garbleScore(text)
            if score < bestScore {
                bestScore = score
                best = text
                if score == 0 { break }
            }
        }
        if !best.isEmpty { return best }
        // 全失败时用「永不失败」的解码，至少保证有内容可显示
        return String(decoding: data, as: UTF8.self)
    }

    /// 乱码打分：替换字符、私有区、控制字符越多分越高
    private static func garbleScore(_ text: String) -> Int {
        var score = 0
        var checked = 0
        for scalar in text.unicodeScalars {
            checked += 1
            if checked > 20_000 { break }
            let value = scalar.value
            if value == 0xFFFD { score += 10 }
            else if (0xE000...0xF8FF).contains(value) { score += 10 }
            else if value < 0x09 { score += 6 }
            else if (0x0B...0x0C).contains(value) { score += 6 }
            else if (0x0E...0x1F).contains(value) { score += 6 }
        }
        return score
    }

    /// 兜底清理：去掉替换字符，避免正文里出现成片「�」
    static func cleanDecoded(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else { return text }
        return text.replacingOccurrences(of: "\u{FFFD}", with: "")
    }
}

