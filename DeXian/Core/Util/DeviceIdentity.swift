import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 设备标识。
///
/// 书源用 `java.deviceID()` 注册账号 / 生成签名（649 处调用、322 个源），
/// 值必须**跨启动稳定**：每次启动都变会导致「刚登录就被判未登录」、
/// 服务端把同一台设备当成新设备。
///
/// 优先用系统提供的 vendor 标识，取不到时退回一份持久化在磁盘上的随机串。
enum DeviceIdentity {

    /// 稳定设备标识（不含短横线的十六进制形式，便于直接塞进 URL）。
    static let identifier: String = {
        #if canImport(UIKit)
        if let value = UIDevice.current.identifierForVendor?.uuidString, !value.isEmpty {
            return value.replacingOccurrences(of: "-", with: "").lowercased()
        }
        #endif
        return persisted
    }()

    /// 落盘的兜底标识。
    private static let persisted: String = {
        let url = FileStorage.url("device-id.txt")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // 去掉短横线并补齐到 16 位，长得像 Android 的 deviceId，
        // 部分书源会对长度做校验。
        var value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        value = String(value.prefix(16))
        try? value.write(to: url, atomically: true, encoding: .utf8)
        return value
    }()
}
