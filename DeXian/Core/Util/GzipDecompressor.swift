import Foundation
import Compression

/// gzip / zlib / deflate 解压。
/// 部分书源仓库以 .gz 分发，导入时需要能解压。
enum GzipDecompressor {

    /// 自动识别 gzip / zlib 并解压，失败返回 nil。
    static func decompress(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }

        // gzip：1f 8b
        if data[0] == 0x1f, data[1] == 0x8b {
            guard let payloadStart = gzipPayloadStart(data) else { return nil }
            let payload = data.subdata(in: payloadStart..<data.count)
            return inflate(payload)
        }

        // zlib：0x78 开头，去掉 2 字节头与 4 字节校验
        if data[0] == 0x78 {
            let payload = data.count > 6 ? data.subdata(in: 2..<(data.count - 4)) : data.dropFirst(2)
            return inflate(payload) ?? inflate(data)
        }

        return nil
    }

    /// 定位 gzip 中 deflate 数据的起始位置（跳过可选字段）
    private static func gzipPayloadStart(_ data: Data) -> Int? {
        guard data.count > 18 else { return nil }
        let flags = data[3]
        var offset = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= data.count else { return nil }
            let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC

        guard offset < data.count else { return nil }
        return offset
    }

    /// 用 Compression 框架解 raw deflate
    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var capacity = max(data.count * 6, 64 * 1024)
        let maximumCapacity = 64 * 1024 * 1024

        while capacity <= maximumCapacity {
            var output = Data(count: capacity)
            let decoded: Int = output.withUnsafeMutableBytes { outputBuffer in
                guard let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return data.withUnsafeBytes { inputBuffer -> Int in
                    guard let inputPointer = inputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        outputPointer, capacity,
                        inputPointer, data.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if decoded > 0, decoded < capacity {
                return output.prefix(decoded)
            }
            if decoded == capacity {
                capacity *= 2
                continue
            }
            // decoded == 0：可能已经是完整解压（正好填满）或失败
            return nil
        }
        return nil
    }
}
