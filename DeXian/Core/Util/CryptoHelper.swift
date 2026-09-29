import Foundation
import CommonCrypto

/// 书源脚本用到的对称加解密（AES / DES / 3DES）。
///
/// 书源里的 java.createSymmetricCrypto("AES/CBC/PKCS5Padding", key, iv)
/// 以及 Packages.javax.crypto.Cipher 最终都要落到真实字节运算上。
/// CommonCrypto 默认不做填充，而 Java 侧的 PKCS5Padding（对 AES 等同 PKCS7）
/// 是默认行为，因此这里显式带上 kCCOptionPKCS7Padding，
/// 否则解密长度不对、明文尾部带垃圾字节 —— 表现就是「正文乱码」。
enum CryptoHelper {

    enum Algorithm {
        case aes
        case des
        case tripleDES

        var keyLengths: [Int] {
            switch self {
            case .aes: return [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256]
            case .des: return [kCCKeySizeDES]
            case .tripleDES: return [kCCKeySize3DES]
            }
        }

        var blockSize: Int {
            self == .aes ? kCCBlockSizeAES128 : kCCBlockSizeDES
        }

        var ccAlgorithm: CCAlgorithm {
            switch self {
            case .aes: return CCAlgorithm(kCCAlgorithmAES)
            case .des: return CCAlgorithm(kCCAlgorithmDES)
            case .tripleDES: return CCAlgorithm(kCCAlgorithm3DES)
            }
        }

        /// 从 "AES/CBC/PKCS5Padding" / "desede" 这类名字里识别算法。
        ///
        /// 顺序很重要：必须先判断 DESede/3DES，再判断 DES，
        /// 否则 "DESede" 会被 "des" 抢先匹配成单倍 DES，
        /// 密钥长度不符导致解密必然失败。
        static func parse(_ text: String) -> Algorithm? {
            let value = text.lowercased().replacingOccurrences(of: "-", with: "")
            if value.contains("aes") { return .aes }
            if value.contains("desede") || value.contains("3des") || value.contains("tripledes") { return .tripleDES }
            if value.contains("des") { return .des }
            return nil
        }
    }

    enum Mode {
        case cbc
        case ecb

        var ccMode: CCMode { self == .cbc ? CCMode(kCCModeCBC) : CCMode(kCCModeECB) }

        static func parse(_ text: String) -> Mode {
            text.lowercased().contains("ecb") ? .ecb : .cbc
        }
    }

    /// 解析 Java 的 transformation 串，例如 "AES/CBC/PKCS5Padding"。
    ///
    /// 识别不出算法时返回 nil，由调用方决定是否记录日志。
    static func parseTransformation(_ text: String) -> (Algorithm, Mode, Bool)? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let algorithm = Algorithm.parse(normalized) else { return nil }
        let mode = Mode.parse(normalized)
        // 显式写了 NoPadding 才关闭填充；其余（PKCS5/PKCS7/ISO10126/空）都按有填充处理。
        let lower = normalized.lowercased()
        let padding = !lower.contains("nopadding") && !lower.contains("no_padding")
        return (algorithm, mode, padding)
    }

    /// 以 transformation 串为入口解密。识别不出算法时返回 nil。
    static func decrypt(_ data: Data, key: Data, iv: Data?, transformation: String, padding: Bool) -> Data? {
        guard let parsed = parseTransformation(transformation) else { return nil }
        return decrypt(data, key: key, iv: iv, algorithm: parsed.0, mode: parsed.1,
                       padding: parsed.2 && padding)
    }

    /// 以 transformation 串为入口加密。识别不出算法时返回 nil。
    static func encrypt(_ data: Data, key: Data, iv: Data?, transformation: String, padding: Bool) -> Data? {
        guard let parsed = parseTransformation(transformation) else { return nil }
        return encrypt(data, key: key, iv: iv, algorithm: parsed.0, mode: parsed.1,
                       padding: parsed.2 && padding)
    }

    /// 把密钥规整到算法允许的长度。
    ///
    /// Java 的 Cipher 在密钥长度非法时会抛异常，书源作者只要写对就不会触发；
    /// 但有些源会把 Base64 解出来的整串直接当密钥用。
    /// 这里取最近的合法长度（不足补零、超出截断），
    /// 让这些源至少能跑出结果，而不是整条规则链报错。
    private static func normalizeKey(_ key: Data, algorithm: Algorithm) -> Data {
        let sizes = algorithm.keyLengths
        if sizes.contains(key.count) { return key }
        let target = sizes.first { $0 >= key.count } ?? sizes[sizes.count - 1]
        if key.count > target { return key.prefix(target) }
        return key + Data(repeating: 0, count: target - key.count)
    }

    static func decrypt(
        _ data: Data,
        key: Data,
        iv: Data?,
        algorithm: Algorithm,
        mode: Mode,
        padding: Bool
    ) -> Data? {
        crypt(operation: CCOperation(kCCDecrypt), data: data, key: key, iv: iv,
              algorithm: algorithm, mode: mode, padding: padding)
    }

    static func encrypt(
        _ data: Data,
        key: Data,
        iv: Data?,
        algorithm: Algorithm,
        mode: Mode,
        padding: Bool
    ) -> Data? {
        crypt(operation: CCOperation(kCCEncrypt), data: data, key: key, iv: iv,
              algorithm: algorithm, mode: mode, padding: padding)
    }

    private static func crypt(
        operation: CCOperation,
        data: Data,
        key: Data,
        iv: Data?,
        algorithm: Algorithm,
        mode: Mode,
        padding: Bool
    ) -> Data? {
        guard !data.isEmpty else { return nil }

        let normalizedKey = normalizeKey(key, algorithm: algorithm)

        // ECB 模式 Java 侧不传 IV；CBC 模式 IV 必须与块长一致，
        // 否则 CommonCrypto 直接返回错误。
        var ivData: Data?
        if mode == .cbc {
            let blockSize = algorithm.blockSize
            let seed = iv ?? Data()
            if seed.count >= blockSize {
                ivData = seed.prefix(blockSize)
            } else {
                ivData = seed + Data(repeating: 0, count: blockSize - seed.count)
            }
        }

        var options = CCOptions(mode.ccMode)
        if padding { options |= CCOptions(kCCOptionPKCS7Padding) }

        let outputCapacity = data.count + algorithm.blockSize * 2
        var output = Data(count: outputCapacity)
        var moved = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBuffer -> CCCryptorStatus in
            guard let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return data.withUnsafeBytes { dataBuffer -> CCCryptorStatus in
                guard let dataPointer = dataBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return CCCryptorStatus(kCCMemoryFailure)
                }
                return normalizedKey.withUnsafeBytes { keyBuffer -> CCCryptorStatus in
                    guard let keyPointer = keyBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return CCCryptorStatus(kCCMemoryFailure)
                    }
                    let run: (UnsafePointer<UInt8>?) -> CCCryptorStatus = { ivPointer in
                        CCCrypt(
                            operation, algorithm.ccAlgorithm, options,
                            keyPointer, normalizedKey.count,
                            ivPointer,
                            dataPointer, data.count,
                            outputPointer, outputCapacity, &moved
                        )
                    }
                    if let ivData, !ivData.isEmpty {
                        return ivData.withUnsafeBytes { ivBuffer -> CCCryptorStatus in
                            run(ivBuffer.bindMemory(to: UInt8.self).baseAddress)
                        }
                    }
                    return run(nil)
                }
            }
        }

        guard status == CCCryptorStatus(kCCSuccess), moved > 0 else { return nil }
        return output.prefix(moved)
    }

    // MARK: - 十六进制

    /// 十六进制字符串 -> 字节。奇数长度或含非法字符时按能解析的部分返回。
    static func hexToData(_ text: String) -> Data {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex,
              let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) {
            if let byte = UInt8(cleaned[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return Data(bytes)
    }

    /// 十六进制字符串 -> Base64（java.HMacBase64 用）。
    static func hexToBase64(_ text: String) -> String {
        hexToData(text).base64EncodedString()
    }
}
