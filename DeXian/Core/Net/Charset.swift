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

    /// 综合解码：BOM > 指定编码 > Content-Type > meta > UTF-8 > GBK
    static func decode(_ data: Data, preferred: String.Encoding? = nil) -> String {
        if data.isEmpty { return "" }

        if let encoding = preferred, let text = String(data: data, encoding: encoding) {
            return text
        }
        if let encoding = fromBOM(data), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let encoding = fromHTMLMeta(data), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let encoding = encoding(named: "gb18030"), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        return ""
    }
}
