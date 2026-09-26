import Foundation

/// 书源导入结果
struct ImportResult {
    var sources: [BookSource] = []
    var skipped: Int = 0
    var warnings: [String] = []
    /// 识别到的格式，用于界面提示
    var detectedFormat: String = "未知"
    /// 结构被识别（但可能没有有效条目），用于区分"不是书源"与"书源字段不全"
    var recognized: Bool = false

    var isEmpty: Bool { sources.isEmpty }
}

/// 多结构书源导入器。
///
/// 目标是“宽进”：尽量接受各类书源仓库 / 分享链接 / 二维码内容的长相。
/// 支持：
/// 1. 标准 JSON 数组（yckceo / Legado 导出）
/// 2. 单个 JSON 对象
/// 3. 带包装的对象（data / sources / bookSources / list / items / result）
/// 4. Base64 编码的 JSON
/// 5. 分享文本中夹杂 JSON（自动截取）
/// 6. 换行分隔的多段 JSON（NDJSON）
/// 7. 含注释 / 尾逗号的宽松 JSON
/// 8. 双层 JSON 字符串（JSON in JSON）
/// 9. 数组元素为对象或 JSON 字符串
/// 10. 网络地址（由上层下载后调用 parse）
enum SourceImporter {

    // MARK: 体积与线程保护

    /// 单次解析允许的最大体积（约 48 MB）。
    /// 几千个书源也远小于这个量级；超过就拒绝，避免把内存打爆。
    static let maxTextBytes = 48 * 1024 * 1024
    /// 宽松 JSON 预处理（去注释 / 截取片段）的体积上限，超过则只走标准 JSON 解析
    static let maxScanBytes = 24 * 1024 * 1024
    /// 分享文本中最多保留多少个 JSON 候选片段
    static let maxCandidates = 8

    enum ImportLimitError: LocalizedError {
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                let mb = Double(bytes) / 1024.0 / 1024.0
                return "内容过大（约 " + String(format: "%.1f", mb) + " MB），已停止解析"
            }
        }
    }

    // MARK: 入口

    /// 从文本解析书源。
    ///
    /// 本方法不依赖任何共享可变状态，可以在后台线程安全调用
    /// （界面请使用 parseInBackground，避免大文件解析阻塞主线程）。
    static func parse(text: String) -> ImportResult {
        var result = ImportResult()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result.warnings.append("内容为空")
            return result
        }

        // 体积闸门：超限直接放弃，宁可失败也不要卡死或闪退
        guard trimmed.utf8.count <= maxTextBytes else {
            let message = ImportLimitError.tooLarge(trimmed.utf8.count).errorDescription ?? "内容过大"
            result.warnings.append(message)
            result.detectedFormat = "内容过大"
            return result
        }

        // 1. Base64
        if looksLikeBase64(trimmed), let decoded = decodeBase64(trimmed) {
            let inner = parse(text: decoded)
            if !inner.isEmpty {
                var merged = inner
                merged.detectedFormat = "Base64 编码的 " + inner.detectedFormat
                return merged
            }
        }

        // 2. 直接当作 JSON
        if let json = parseJSON(trimmed) {
            let extraction = extract(from: json)
            if !extraction.sources.isEmpty || extraction.recognized {
                var output = extraction
                if output.detectedFormat == "未知" { output.detectedFormat = "JSON 数组" }
                return output
            }
        }

        // 3. 分享文本 / NDJSON / 宽松 JSON：截取候选片段
        for candidate in jsonCandidates(in: trimmed) {
            if let json = parseJSON(candidate) {
                let extraction = extract(from: json)
                if !extraction.sources.isEmpty {
                    var output = extraction
                    if output.detectedFormat == "未知" { output.detectedFormat = "分享文本中的 JSON" }
                    return output
                }
            }
        }

        // 4. 每行一个 JSON（部分工具导出格式）
        var lineSources: [BookSource] = []
        var lineSkipped = 0
        var recognizedAny = false
        for line in trimmed.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("{"), value.hasSuffix("}") else { continue }
            recognizedAny = true
            if let json = parseJSON(value) {
                let extraction = extract(from: json)
                lineSources.append(contentsOf: extraction.sources)
                lineSkipped += extraction.skipped
            } else {
                lineSkipped += 1
            }
        }
        if !lineSources.isEmpty {
            result.sources = lineSources
            result.skipped = lineSkipped
            result.detectedFormat = "每行一个 JSON（NDJSON）"
            return result
        }
        if recognizedAny {
            result.skipped = max(lineSkipped, 1)
            result.warnings.append("识别到 JSON 行，但字段不完整")
            return result
        }

        result.warnings.append("未能识别书源格式")
        return result
    }

    /// 在后台线程解析，供界面使用（大文件不会卡住主线程）。
    static func parseInBackground(text: String) async -> ImportResult {
        await Background.run { parse(text: text) }
    }

    /// 后台读取并解析文件（含体积预检，避免一次性读入超大文件）
    static func importInBackground(fromFile url: URL) async -> ImportResult {
        // 先看文件大小，超限就不读了
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maxTextBytes {
            var result = ImportResult()
            result.warnings.append(ImportLimitError.tooLarge(size).errorDescription ?? "内容过大")
            result.detectedFormat = "内容过大"
            return result
        }

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        return await Background.run {
            guard let data = try? Data(contentsOf: url) else {
                var result = ImportResult()
                result.warnings.append("文件读取失败")
                return result
            }
            return parse(text: Charset.decode(data))
        }
    }

    /// 从网络地址导入（支持重定向与纯文本）
    static func import(from urlString: String) async throws -> ImportResult {
        let response = try await HTTPClient.shared.request(urlString: urlString, options: HTTPRequestOptions())
        var result = parse(text: response.text)
        if result.isEmpty {
            // 有些链接直接指向文件，尝试用最终 URL 再取一次
            if let finalURL = response.finalURL?.absoluteString, finalURL != urlString {
                let retry = try await HTTPClient.shared.request(urlString: finalURL, options: HTTPRequestOptions())
                result = parse(text: retry.text)
            }
        }
        if !result.isEmpty {
            result.detectedFormat += "（来自网络）"
        }
        return result
    }

    /// 读取本文件（JSON / txt）
    static func import(fromFile url: URL) -> ImportResult {
        guard let data = try? Data(contentsOf: url) else {
            var result = ImportResult()
            result.warnings.append("文件读取失败")
            return result
        }
        return parse(text: Charset.decode(data))
    }

    // MARK: 结构提取

    /// 从任意 JSON 结构中提取书源列表，兼容各种包装。
    private static func extract(from json: Any) -> ImportResult {
        var result = ImportResult()

        // 单对象
        if let dictionary = json as? [String: Any] {
            if isSourceLike(dictionary) {
                if let source = makeSource(dictionary) {
                    result.sources = [source]
                    result.detectedFormat = "单个书源对象"
                } else {
                    result.skipped = 1
                }
                result.detectedFormat = "单个书源对象"
                return result
            }

            // 包装字段
            let wrapperKeys = ["data", "sources", "bookSources", "bookSourceList", "list",
                               "items", "result", "results", "sourcesList", "content"]
            var sawWrapper = false
            for key in wrapperKeys {
                guard let value = dictionary[key] else { continue }
                sawWrapper = true
                let inner = extract(from: value)
                if !inner.isEmpty { return inner }
            }
            if sawWrapper { result.recognized = true }

            // 书源名 -> 书源 的映射形式
            if let mapping = dictionary as? [String: Any], mapping.count > 0 {
                var sources: [BookSource] = []
                var skipped = 0
                for (name, value) in mapping {
                    guard let item = value as? [String: Any] else { continue }
                    var mutable = item
                    if mutable["bookSourceName"] == nil { mutable["bookSourceName"] = name }
                    if let source = makeSource(mutable) { sources.append(source) } else { skipped += 1 }
                }
                if !sources.isEmpty {
                    result.sources = sources
                    result.skipped = skipped
                    result.recognized = true
                    result.detectedFormat = "书源名到书源的映射"
                    return result
                }
            }
            return result
        }

        // 数组
        if let array = json as? [Any] {
            var sources: [BookSource] = []
            var skipped = 0
            for item in array {
                if let dictionary = item as? [String: Any] {
                    if let source = makeSource(dictionary) { sources.append(source) } else { skipped += 1 }
                } else if let text = item as? String {
                    // 数组里放 JSON 字符串
                    if let nested = text.jsonObject as? [String: Any], let source = makeSource(nested) {
                        sources.append(source)
                    } else {
                        skipped += 1
                    }
                } else {
                    skipped += 1
                }
            }
            result.sources = sources
            result.skipped = skipped
            result.recognized = true
            result.detectedFormat = "JSON 数组（" + String(sources.count) + " 个书源）"
            if sources.isEmpty, !array.isEmpty {
                result.warnings.append("数组里的条目缺少书源字段")
            }
            return result
        }

        // 纯字符串（可能是内层 JSON）
        if let text = json as? String {
            return parse(text: text)
        }
        return result
    }

    /// 判断字典是否像一个书源
    private static func isSourceLike(_ dictionary: [String: Any]) -> Bool {
        let markers = ["bookSourceUrl", "bookSourceName", "bookSourceType", "ruleSearch",
                       "ruleToc", "ruleContent", "searchUrl", "exploreUrl", "sourceUrl"]
        for marker in markers where dictionary[marker] != nil { return true }
        // 至少要同时有名和地址才当作书源
        let hasName = dictionary["bookSourceName"] != nil || dictionary["name"] != nil
        let hasURL = dictionary["bookSourceUrl"] != nil || dictionary["url"] != nil
        return hasName && hasURL
    }

    static func makeSource(_ dictionary: [String: Any]) -> BookSource? {
        let name = dictionary.str("bookSourceName", "sourceName", "name", "title") ?? ""
        let url = dictionary.str("bookSourceUrl", "bookSourceURL", "sourceUrl", "url", "baseUrl", "host") ?? ""
        // 名和地址都没有 => 不是书源
        if name.isBlank && url.isBlank { return nil }
        return BookSource(dict: dictionary)
    }

    // MARK: JSON 容错解析

    /// 宽松 JSON 解析：去注释、去尾逗号、修复裸控制字符。
    static func parseJSON(_ text: String) -> Any? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return object
        }

        value = sanitizeJSON(value)
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return object
        }

        // 去掉控制字符后再试一次
        let cleaned = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" || scalar == "\r"
        }
        let cleanedText = String(String.UnicodeScalarView(cleaned))
        guard let data = cleanedText.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: 宽松 JSON 预处理（内存友好）

    /// 移除 JS 风格注释与尾随逗号。
    ///
    /// 实现按 UTF-8 字节扫描，峰值内存约等于原文大小；
    /// 旧实现会先把整份文本转成 [Character]（放大十几倍），大文件容易崩。
    static func sanitizeJSON(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count <= maxScanBytes else { return text }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var index = 0
        var inString = false
        var quote: UInt8 = 0
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {           // 反斜杠
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 || byte == 0x27 {       // " 或 '
                inString = true
                quote = byte
                output.append(byte)
                index += 1
                continue
            }

            // 行注释
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            }
            // 块注释
            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < bytes.count,
                      !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                index += 2
                continue
            }

            output.append(byte)
            index += 1
        }

        guard let raw = String(bytes: output, encoding: .utf8) else { return text }
        return removeTrailingCommas(raw)
    }

    /// 去掉 ,} 与 ,] 里的多余逗号
    private static func removeTrailingCommas(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ",\\s*([}\\]])") else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
    }

    /// 在混杂文本中找出所有平衡的 JSON 片段（长的优先）。
    ///
    /// 同样按字节扫描；只保留前 maxCandidates 个片段，避免超大分享文本产生海量候选。
    static func jsonCandidates(in text: String) -> [String] {
        let bytes = Array(text.utf8)
        guard bytes.count <= maxScanBytes else { return [] }

        var candidates: [String] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x5B || byte == 0x7B else { index += 1; continue }   // [ 或 {
            guard let end = findBalancedEnd(bytes, from: index) else { index += 1; continue }
            let length = end - index + 1
            if length > 20, let candidate = String(bytes: bytes[index...end], encoding: .utf8) {
                candidates.append(candidate)
                if candidates.count >= 64 { break }
            }
            index = end + 1
        }

        return candidates
            .sorted { $0.utf8.count > $1.utf8.count }
            .prefix(maxCandidates)
            .map { $0 }
    }

    /// 从 start 开始找配对结束位置（按字节，字符串内的括号不计数）。
    private static func findBalancedEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var index = start
        var inString = false
        var quote: UInt8 = 0
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == quote { inString = false }
                index += 1
                continue
            }

            if byte == 0x22 || byte == 0x27 { inString = true; quote = byte; index += 1; continue }
            if byte == 0x5B || byte == 0x7B { depth += 1 }                  // [ {
            if byte == 0x5D || byte == 0x7D {                               // ] }
                depth -= 1
                if depth == 0 { return index }
                if depth < 0 { return nil }
            }
            index += 1
        }
        return nil
    }

    // MARK: Base64

    static func looksLikeBase64(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count > 24, !value.contains("{"), !value.contains("[") else { return false }
        for scalar in value.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "=", "\n", "\r":
                continue
            default:
                return false
            }
        }
        return true
    }

    static func decodeBase64(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters) else { return nil }
        if let gzip = GzipDecompressor.decompress(data) {
            return Charset.decode(gzip)
        }
        return Charset.decode(data)
    }

    static func merge(existing: [BookSource], incoming: [BookSource]) -> (result: [BookSource], added: Int, updated: Int) {
        var indexMap: [String: Int] = [:]
        var merged = existing
        for (offset, source) in existing.enumerated() {
            indexMap[source.id] = offset
        }
        var added = 0
        var updated = 0
        for source in incoming {
            if let offset = indexMap[source.id] {
                merged[offset] = source
                updated += 1
            } else {
                indexMap[source.id] = merged.count
                merged.append(source)
                added += 1
            }
        }
        return (merged, added, updated)
    }
}
