import Foundation

/// 最小可用的 ZIP 读取器（仅「读单个条目」，不建目录树）。
///
/// 书源的 `java.getZipStringContent(url, "detail.json")` 需要从远端 zip 里
/// 取出指定条目当作正文 / 详情。实测 32 个源用它，缺失时是
/// `undefined is not a function`，这些源的详情页整页空白。
///
/// 只做必须的两件事：定位「中央目录」找到条目偏移，再按压缩方法解压。
/// 不引入第三方依赖（本工程无 Package.swift，只有 Xcode 工程）。
enum ZipArchive {

    /// 条目名 -> 原始压缩数据（含 local header）。
    private struct Entry {
        var name: String
        var method: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// 取出名为 `name` 的条目内容。
    ///
    /// 条目名比较做「忽略首尾斜杠 / 大小写不敏感」的宽松匹配：
    /// 书源里写 `'detail.json'` 而包内实际是 `/detail.json` 的情况很常见。
    static func content(of name: String, in data: Data) -> Data? {
        guard let entry = findEntry(named: name, in: data) else { return nil }
        return read(entry, from: data)
    }

    /// 包内全部条目名（调试用，也用于「名字完全对不上时退化取第一个」）。
    static func entryNames(in data: Data) -> [String] {
        entries(in: data).map { $0.name }
    }

    // MARK: 解析

    private static func findEntry(named name: String, in data: Data) -> Entry? {
        let all = entries(in: data)
        guard !all.isEmpty else { return nil }
        let target = normalize(name)
        if let exact = all.first(where: { normalize($0.name) == target }) { return exact }
        // 宽松匹配：包内路径带目录前缀（`assets/detail.json`）
        if let suffix = all.first(where: { normalize($0.name).hasSuffix("/" + target) }) { return suffix }
        if let contains = all.first(where: { normalize($0.name).contains(target) }) { return contains }
        // 名字完全对不上时取第一个条目，总比返回空强
        return all.first
    }

    private static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    /// 从「中央目录结束记录」反向定位中央目录，逐条解析。
    private static func entries(in data: Data) -> [Entry] {
        guard data.count > 22 else { return [] }
        guard let eocd = findEOCD(data) else { return [] }

        let total = Int(u16(data, eocd + 10))
        var offset = Int(u32(data, eocd + 16))
        var result: [Entry] = []
        result.reserveCapacity(min(total, 4096))

        for _ in 0..<min(total, 65535) {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4b50 else { break }
            let method = Int(u16(data, offset + 10))
            let compressed = Int(u32(data, offset + 20))
            let uncompressed = Int(u32(data, offset + 24))
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            let localOffset = Int(u32(data, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = Charset.decode(nameData)
            result.append(Entry(name: name, method: method,
                                compressedSize: compressed,
                                uncompressedSize: uncompressed,
                                localHeaderOffset: localOffset))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    /// 定位中央目录结束记录（从尾部往前找，最多回看 64KB）。
    private static func findEOCD(_ data: Data) -> Int? {
        let minimum = 22
        let lowerBound = max(0, data.count - 65557)
        var index = data.count - minimum
        while index >= lowerBound {
            if u32(data, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    /// 读出条目数据（跳过 local header，按压缩方法解压）。
    private static func read(_ entry: Entry, from data: Data) -> Data? {
        let start = entry.localHeaderOffset
        guard start + 30 <= data.count, u32(data, start) == 0x0403_4b50 else { return nil }
        let nameLength = Int(u16(data, start + 26))
        let extraLength = Int(u16(data, start + 28))
        let payloadStart = start + 30 + nameLength + extraLength
        guard payloadStart <= data.count else { return nil }

        // 中央目录里的 size 可能为 0（流式写入的包），此时用「下一个条目」兜底。
        var size = entry.compressedSize
        if size <= 0 {
            size = max(0, data.count - payloadStart)
        }
        let end = min(data.count, payloadStart + size)
        guard payloadStart < end else { return nil }
        let payload = data.subdata(in: payloadStart..<end)

        switch entry.method {
        case 0:  return payload
        case 8:  return GzipDecompressor.inflate(payload)
        default: return nil
        }
    }

    // MARK: 小端读取

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
