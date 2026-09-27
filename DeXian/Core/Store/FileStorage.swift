import Foundation

/// 极简的 JSON 文件存储：原子写入 + 应用支持目录。
///
/// 书源动辄几千个，yckceo 上单个书源平均 40KB 以上，
/// 全量 JSON 可以轻松超过 100MB。原来的实现有三个致命点：
///
/// 1. `Data(contentsOf:)` 把整个文件读进内存；
/// 2. `JSONDecoder` 一次性把全部条目解码成结构体；
/// 3. `save` 用 `.prettyPrinted` 编码，文件再膨胀三分之一。
///
/// 结果就是「导入几千个书源后，一打开就闪退」——
/// 启动时在主线程上把上百 MB 数据同时驻留，直接被系统 Jetsam 杀掉。
///
/// 现在读取走内存映射 + 按元素分块解码，写入走流式拼接，
/// 峰值内存与书源数量无关，只有「单个书源」那么大。
struct FileStorage {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeXian", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// 内存映射读取：文件页按需载入，内存紧张时系统可以直接回收，
    /// 不会在启动瞬间要求一块和文件同样大的常驻内存。
    static func data(_ name: String) -> Data? {
        try? Data(contentsOf: url(name), options: .mappedIfSafe)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = data(name) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// 分块解码顶层 JSON 数组。
    ///
    /// 先把数组切成每个元素的字节区间，再逐个解码并立刻释放：
    /// 峰值内存只取决于「最大的那个书源」，而不是书源总数。
    /// 元素之间靠 `Data` 切片共享底层缓冲，切片本身不复制数据。
    static func loadArray<T: Decodable>(_ type: T.Type, from name: String) -> [T]? {
        guard let data = data(name), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let ranges = arrayElementRanges(data), !ranges.isEmpty else {
            // 不是顶层数组（或扫描失败）：退回一次性解码
            return try? decoder.decode([T].self, from: data)
        }

        var output: [T] = []
        output.reserveCapacity(ranges.count)
        for range in ranges {
            // 每个元素解码完立刻释放中间对象树
            autoreleasepool {
                if let value = try? decoder.decode(T.self, from: data[range]) {
                    output.append(value)
                }
            }
        }
        return output
    }

    /// 流式写入顶层数组：逐元素编码后直接追加到文件，
    /// 全程只驻留一个元素的 Data，避免导入后第一次写盘就被打死。
    static func saveArray<T: Encodable>(_ values: [T], to name: String) {
        let target = url(name)
        let temporary = target.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]

        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temporary) else { return }
        var ok = true
        do {
            try handle.write(contentsOf: Data("[".utf8))
            var first = true
            for value in values {
                let chunk: Data? = autoreleasepool {
                    guard let encoded = try? encoder.encode(value) else { return nil }
                    return encoded
                }
                guard let chunk else { ok = false; break }
                if !first { try handle.write(contentsOf: Data(",".utf8)) }
                first = false
                try handle.write(contentsOf: chunk)
            }
            if ok { try handle.write(contentsOf: Data("]".utf8)) }
        } catch {
            ok = false
        }
        try? handle.close()

        guard ok else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: temporary, to: target)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 不再 prettyPrinted：存储用的文件越小，编码时的内存峰值越低，
        // 用户需要看的那份由 exportJSON 单独格式化。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }

    /// 原始文本读写（用于导入导出书源 JSON）
    static func loadText(_ name: String) -> String? {
        try? String(contentsOf: url(name), encoding: .utf8)
    }

    static func saveText(_ text: String, to name: String) {
        try? text.write(to: url(name), atomically: true, encoding: .utf8)
    }

    // MARK: 顶层数组切分

    /// 找出顶层数组里每个元素的字节区间（只认对象 / 数组元素）。
    ///
    /// 纯字节扫描：UTF-8 的多字节字符不会出现 ASCII 值，
    /// 所以按字节判断 `" ` `[ ` `] ` `{ ` `} ` 是安全的。
    /// 直接在 `Data` 的底层缓冲上扫描，不复制。
    ///
    /// 早期写成 `let bytes = [UInt8](data)`，等于把整个文件
    /// （书源全量可上百 MB）又复制一份到内存，
    /// 启动瞬间内存翻倍，正好撞上系统 Jetsam。
    static func arrayElementRanges(_ data: Data) -> [Range<Int>]? {
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { raw in
            let count = raw.count
            var index = 0

            // 找到第一个非空白字符，必须是 [
            while index < count, isWhitespace(raw[index]) { index += 1 }
            guard index < count, raw[index] == 0x5B else { return }
            index += 1

            var depth = 0
            var elementStart = -1
            var inString = false
            var escaped = false

            while index < count {
                let byte = raw[index]

                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                    index += 1
                    continue
                }

                switch byte {
                case 0x22:                              // "
                    if elementStart < 0 { elementStart = index }
                    inString = true
                case 0x5B, 0x7B:                        // [ {
                    if elementStart < 0 { elementStart = index }
                    depth += 1
                case 0x5D, 0x7D:                        // ] }
                    depth -= 1
                    if depth == 0, elementStart >= 0 {
                        ranges.append(elementStart..<(index + 1))
                        elementStart = -1
                    }
                    if depth < 0 { return }
                case 0x2C where depth == 0:             // ,
                    elementStart = -1
                default:
                    if !isWhitespace(byte), elementStart < 0 { elementStart = index }
                }
                index += 1
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
