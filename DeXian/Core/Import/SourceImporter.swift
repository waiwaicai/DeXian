import Foundation

/// 书源导入结果
struct ImportResult {
    var sources: [BookSource] = []
    /// 识别到的订阅源（RSS）。与书源分开存放，字段结构不同。
    var rssSources: [RssSource] = []
    var skipped: Int = 0
    var warnings: [String] = []
    /// 识别到的格式，用于界面提示
    var detectedFormat: String = "未知"
    /// 结构被识别（但可能没有有效条目），用于区分"不是书源"与"书源字段不全"
    var recognized: Bool = false

    var isEmpty: Bool { sources.isEmpty && rssSources.isEmpty }
    var hasBookSources: Bool { !sources.isEmpty }
    var hasRssSources: Bool { !rssSources.isEmpty }
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
    /// 大书源合集的专用导入下载超时；普通书源请求仍使用全局 15/30 秒保护。
    static let importDownloadTimeout: TimeInterval = 180

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
    static func parse(text: String, preferRss: Bool = false) -> ImportResult {
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
            let inner = parse(text: decoded, preferRss: preferRss)
            if !inner.isEmpty {
                var merged = inner
                merged.detectedFormat = "Base64 编码的 " + inner.detectedFormat
                return merged
            }
        }

        // 2. 直接当作 JSON
        if let json = parseJSON(trimmed) {
            let extraction = extract(from: json, preferRss: preferRss)
            if !extraction.isEmpty || extraction.recognized {
                var output = extraction
                if output.detectedFormat == "未知" { output.detectedFormat = "JSON 数组" }
                return output
            }
        }

        // 3. 每行一个 JSON（NDJSON）：必须先于“分享文本片段截取”。
        //    片段截取遇到第一个平衡的 {} 就会返回，会把多行 NDJSON 截成一行。
        var lineSources: [BookSource] = []
        var lineRssSources: [RssSource] = []
        var lineSkipped = 0
        var candidateLines = 0
        for line in trimmed.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("{"), value.hasSuffix("}") else { continue }
            candidateLines += 1
            if let json = parseJSON(value) {
                let extraction = extract(from: json, preferRss: preferRss)
                if extraction.isEmpty {
                    lineSkipped += max(extraction.skipped, 1)
                } else {
                    lineSources.append(contentsOf: extraction.sources)
                    lineRssSources.append(contentsOf: extraction.rssSources)
                }
            } else {
                lineSkipped += 1
            }
        }
        // 至少两行、且每一行都成功解析出书源，才认定为 NDJSON；
        // 否则「首行是 JSON + 后面是说明文字」会被误判。
        if candidateLines >= 2, lineSkipped == 0, !lineSources.isEmpty || !lineRssSources.isEmpty {
            result.sources = lineSources
            result.rssSources = lineRssSources
            result.skipped = 0
            result.detectedFormat = "每行一个 JSON（NDJSON）"
            return result
        }

        // 4. 分享文本 / 宽松 JSON：截取候选片段
        for candidate in jsonCandidates(in: trimmed) {
            if let json = parseJSON(candidate) {
                let extraction = extract(from: json, preferRss: preferRss)
                if !extraction.isEmpty {
                    var output = extraction
                    if output.detectedFormat == "未知" { output.detectedFormat = "分享文本中的 JSON" }
                    return output
                }
            }
        }

        result.warnings.append("未能识别书源格式")
        return result
    }

    /// 在后台线程解析，供界面使用（大文件不会卡住主线程）。
    static func parseInBackground(text: String, preferRss: Bool = false) async -> ImportResult {
        await Background.run { parse(text: text, preferRss: preferRss) }
    }

    /// 后台读取并解析文件（含体积预检，避免一次性读入超大文件）
    static func importInBackground(fromFile url: URL, preferRss: Bool = false) async -> ImportResult {
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
            return parse(text: Charset.decode(data), preferRss: preferRss)
        }
    }

    /// 从网络地址导入（支持重定向与纯文本）。
    ///
    /// 1305 这类合集有 7.7MB / 898 个源，手机网络下可能超过 30 秒。
    /// 导入链路使用专用长超时，普通书源请求仍保持现有全局保护。
    static func importFromURL(_ urlString: String, preferRss: Bool = false) async throws -> ImportResult {
        let options = HTTPRequestOptions(timeout: SourceImporter.importDownloadTimeout)
        let response = try await HTTPClient.shared.request(urlString: urlString, options: options)
        var result = parse(text: response.text, preferRss: preferRss)
        if result.isEmpty {
            // 有些链接直接指向文件，尝试用最终 URL 再取一次
            if let finalURL = response.finalURL?.absoluteString, finalURL != urlString {
                let retry = try await HTTPClient.shared.request(urlString: finalURL, options: options)
                result = parse(text: retry.text, preferRss: preferRss)
            }
        }
        if !result.isEmpty {
            result.detectedFormat += "（来自网络）"
        }
        return result
    }

    /// 读取本文件（JSON / txt）
    static func importFromFile(_ url: URL, preferRss: Bool = false) -> ImportResult {
        guard let data = try? Data(contentsOf: url) else {
            var result = ImportResult()
            result.warnings.append("文件读取失败")
            return result
        }
        return parse(text: Charset.decode(data), preferRss: preferRss)
    }

    // MARK: 结构提取

    /// 从任意 JSON 结构中提取书源列表，兼容各种包装。
    private static func extract(from json: Any, preferRss: Bool = false) -> ImportResult {
        var result = ImportResult()

        // 单对象
        if let dictionary = json as? [String: Any] {
            switch kindOf(dictionary, preferRss: preferRss) {
            case .book:
                if let source = makeSource(dictionary) {
                    result.sources = [source]
                    result.detectedFormat = "单个书源对象"
                } else {
                    result.skipped = 1
                    result.recognized = true
                }
                return result
            case .rss:
                if let source = makeRssSource(dictionary) {
                    result.rssSources = [source]
                    result.detectedFormat = "单个订阅源对象"
                } else {
                    result.skipped = 1
                }
                result.recognized = true
                return result
            case .none:
                break
            }

            // 包装字段
            let wrapperKeys = ["data", "sources", "bookSources", "bookSourceList", "list",
                               "items", "result", "results", "sourcesList", "content"]
            var sawWrapper = false
            for key in wrapperKeys {
                guard let value = dictionary[key] else { continue }
                sawWrapper = true
                let inner = extract(from: value, preferRss: preferRss)
                if !inner.isEmpty { return inner }
            }
            if sawWrapper { result.recognized = true }

            // 书源名 -> 书源 的映射形式
            if let mapping = dictionary as? [String: Any], mapping.count > 0 {
                var sources: [BookSource] = []
                var rssSources: [RssSource] = []
                var skipped = 0
                for (name, value) in mapping {
                    guard let item = value as? [String: Any] else { continue }
                    var mutable = item
                    if mutable["bookSourceName"] == nil { mutable["bookSourceName"] = name }
                    switch kindOf(mutable, preferRss: preferRss) {
                    case .book:
                        if let source = makeSource(mutable) { sources.append(source) } else { skipped += 1 }
                    case .rss:
                        if let source = makeRssSource(mutable) { rssSources.append(source) } else { skipped += 1 }
                    case .none:
                        skipped += 1
                    }
                }
                if !sources.isEmpty || !rssSources.isEmpty {
                    result.sources = sources
                    result.rssSources = rssSources
                    result.skipped = skipped
                    result.recognized = true
                    result.detectedFormat = "名称到源对象的映射"
                    return result
                }
            }
            return result
        }

        // 数组
        if let array = json as? [Any] {
            var sources: [BookSource] = []
            var rssSources: [RssSource] = []
            var skipped = 0
            for item in array {
                var dictionary: [String: Any]?
                if let value = item as? [String: Any] {
                    dictionary = value
                } else if let text = item as? String {
                    // 数组里放 JSON 字符串
                    dictionary = text.jsonObject as? [String: Any]
                }
                guard let entry = dictionary else { skipped += 1; continue }
                switch kindOf(entry, preferRss: preferRss) {
                case .book:
                    if let source = makeSource(entry) { sources.append(source) } else { skipped += 1 }
                case .rss:
                    if let source = makeRssSource(entry) { rssSources.append(source) } else { skipped += 1 }
                case .none:
                    skipped += 1
                }
            }
            result.sources = sources
            result.rssSources = rssSources
            result.skipped = skipped
            result.recognized = true
            if !rssSources.isEmpty && sources.isEmpty {
                result.detectedFormat = "JSON 数组（" + String(rssSources.count) + " 个订阅源）"
                return result
            }
            if !rssSources.isEmpty {
                result.detectedFormat = "JSON 数组（" + String(sources.count) + " 个书源 + "
                    + String(rssSources.count) + " 个订阅源）"
                return result
            }
            result.detectedFormat = "JSON 数组（" + String(sources.count) + " 个书源）"
            if sources.isEmpty, !array.isEmpty {
                result.warnings.append("数组里的条目缺少书源字段")
            }
            return result
        }

        // 纯字符串（可能是内层 JSON）
        if let text = json as? String {
            return parse(text: text, preferRss: preferRss)
        }
        return result
    }

    /// 条目类型：书源 / 订阅源 / 无法识别
    enum SourceKind {
        case book
        case rss
        case none
    }

    /// 判断一个条目是书源还是订阅源。
    ///
    /// 两者字段名高度重合（都有 name/url/enabled），靠"独有字段"区分：
    /// - 书源独有：bookSourceName / ruleSearch / ruleToc / exploreUrl
    /// - 订阅源独有：ruleArticles / ruleTitle / ruleLink / articleStyle / sortUrl
    /// 只有 ruleContent 时优先当作订阅源（书源的正文规则在 ruleContent.content 下）。
    static func kindOf(_ dictionary: [String: Any], preferRss: Bool = false) -> SourceKind {
        if dictionary["bookSourceName"] != nil || dictionary["bookSourceUrl"] != nil { return .book }
        if dictionary["ruleSearch"] != nil || dictionary["ruleToc"] != nil
            || dictionary["ruleBookInfo"] != nil || dictionary["exploreUrl"] != nil {
            return .book
        }
        if dictionary["ruleArticles"] != nil || dictionary["ruleTitle"] != nil
            || dictionary["ruleLink"] != nil || dictionary["rulePubDate"] != nil
            || dictionary["articleStyle"] != nil {
            return .rss
        }
        if dictionary["sortUrl"] != nil { return .rss }
        // articleStyle / loadWithBaseUrl / singleUrl 是订阅源字段，书源不使用，
        // 因此哪怕没有任何规则也能判定为订阅源（例：源仓库官方纯净）。
        if dictionary["loadWithBaseUrl"] != nil && dictionary["bookSourceType"] == nil { return .rss }
        let hasName = dictionary["sourceName"] != nil || dictionary["name"] != nil
            || dictionary["bookSourceName"] != nil || dictionary["title"] != nil
        let hasURL = dictionary["sourceUrl"] != nil || dictionary["url"] != nil
            || dictionary["bookSourceUrl"] != nil
        guard hasName, hasURL else { return .none }
        // 调用方明确声明按订阅源导入（RSS 页签 / 订阅源文件）时以此为准
        if preferRss { return .rss }
        // 有正文规则但没有任何书籍结构时，按订阅源处理
        if dictionary["ruleContent"] != nil { return .rss }
        // 名字里带"订阅"的按订阅源处理
        let name = dictionary.str("sourceName", "name", "title") ?? ""
        if name.contains("订阅") { return .rss }
        return .book
    }

    static func makeSource(_ dictionary: [String: Any]) -> BookSource? {
        let name = dictionary.str("bookSourceName", "sourceName", "name", "title") ?? ""
        let url = dictionary.str("bookSourceUrl", "bookSourceURL", "sourceUrl", "url", "baseUrl", "host") ?? ""
        // 名和地址都没有 => 不是书源
        if name.isBlank && url.isBlank { return nil }
        return BookSource(dict: dictionary)
    }

    static func makeRssSource(_ dictionary: [String: Any]) -> RssSource? {
        let name = dictionary.str("sourceName", "name", "title") ?? ""
        let url = dictionary.str("sourceUrl", "url", "baseUrl", "host") ?? ""
        // 订阅源至少要能定位到内容：有地址，或有搜索地址
        let search = dictionary.str("searchUrl") ?? ""
        if url.isBlank && search.isBlank { return nil }
        if name.isBlank && url.isBlank { return nil }
        return RssSource(dict: dictionary)
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
        // 先给已有数据去重：历史版本可能写下 id 重复的书源，
        // 重复 id 进入 SwiftUI 列表会直接 fatalError 崩溃。
        var existingSeen = Set<String>()
        var merged = existing.filter { existingSeen.insert($0.id).inserted }
        for (offset, source) in merged.enumerated() {
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
