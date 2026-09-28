import Foundation
import CoreFoundation

/// 宽容的 JSON 取值工具。
/// 书源生态里同一个字段可能是字符串 / 数字 / 布尔 / null，
/// 这里统一做类型归一化，是“兼容多种书源结构”的基础。
func asString(_ any: Any?) -> String? {
    switch any {
    case nil, is NSNull:
        return nil
    case let value as String:
        return value
    case let value as NSString:
        return value as String
    case let value as NSNumber:
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value.boolValue ? "true" : "false"
        }
        let doubleValue = value.doubleValue
        if doubleValue == doubleValue.rounded(), abs(doubleValue) < 1e15 {
            return String(Int64(doubleValue))
        }
        return value.stringValue
    case let value as Bool:
        return value ? "true" : "false"
    case let value as Int:
        return String(value)
    case let value as Double:
        return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    case let value as [Any]:
        // 先净化：容器里可能混着 HTMLNode 这类纯 Swift 值，
        // 直接交给 JSONSerialization 会抛 ObjC 异常，try? 抓不住，进程直接终止。
        guard let safe = RuleUtil.jsonSafeObject(value) else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: safe),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    case let value as [String: Any]:
        guard let safe = RuleUtil.jsonSafeObject(value) else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: safe),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    default:
        return String(describing: any!)
    }
}

func asDict(_ any: Any?) -> [String: Any]? {
    if let value = any as? [String: Any] { return value }
    if let value = any as? NSDictionary {
        var result: [String: Any] = [:]
        for (key, item) in value {
            if let key = asString(key) { result[key] = item }
        }
        return result.isEmpty ? nil : result
    }
    if let text = any as? String,
       let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) {
        return asDict(object)
    }
    return nil
}

func asArray(_ any: Any?) -> [Any]? {
    if let value = any as? [Any] { return value }
    if let value = any as? NSArray { return value.map { $0 } }
    if let text = any as? String,
       let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) {
        return asArray(object)
    }
    return nil
}

func asDictArray(_ any: Any?) -> [[String: Any]] {
    guard let array = asArray(any) else {
        if let single = asDict(any) { return [single] }
        return []
    }
    return array.compactMap { asDict($0) }
}

func asBool(_ any: Any?, default defaultValue: Bool = false) -> Bool {
    switch any {
    case nil, is NSNull:
        return defaultValue
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    case let value as String:
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["true", "1", "yes", "y", "on"].contains(lowered) { return true }
        if ["false", "0", "no", "n", "off", ""].contains(lowered) { return false }
        return defaultValue
    default:
        return defaultValue
    }
}

func asInt(_ any: Any?) -> Int? {
    switch any {
    case nil, is NSNull:
        return nil
    case let value as Int:
        return value
    case let value as NSNumber:
        return value.intValue
    case let value as String:
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intValue = Int(trimmed) { return intValue }
        if let doubleValue = Double(trimmed) { return Int(doubleValue) }
        return nil
    case let value as Double:
        return Int(value)
    default:
        return nil
    }
}

func asDouble(_ any: Any?) -> Double? {
    switch any {
    case nil, is NSNull:
        return nil
    case let value as Double:
        return value
    case let value as NSNumber:
        return value.doubleValue
    case let value as String:
        return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    case let value as Int:
        return Double(value)
    default:
        return nil
    }
}

extension Dictionary where Key == String, Value == Any {
    /// 按顺序返回第一个存在（非 null）的键，用于字段别名兼容。
    func firstValue(_ keys: [String]) -> Any? {
        for key in keys {
            if let value = self[key], !(value is NSNull) { return value }
        }
        return nil
    }

    func str(_ keys: String...) -> String? {
        asString(firstValue(keys))
    }

    func dict(_ keys: String...) -> [String: Any]? {
        asDict(firstValue(keys))
    }

    func arr(_ keys: String...) -> [Any]? {
        asArray(firstValue(keys))
    }

    func bool(_ keys: String...) -> Bool {
        asBool(firstValue(keys))
    }

    /// 指定默认值的布尔取值（变参需位于参数表末尾）。
    func bool(_ defaultValue: Bool, _ keys: String...) -> Bool {
        asBool(firstValue(keys), default: defaultValue)
    }

    func int(_ keys: String...) -> Int? {
        asInt(firstValue(keys))
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool {
        trimmed.isEmpty
    }

    /// 书源规则里常见 "" 与 "null"，需要按“空”处理。
    var nilIfBlank: String? {
        let value = trimmed
        if value.isEmpty { return nil }
        if value == "null" || value == "nil" { return nil }
        return self
    }

    /// 解析 JSON 字符串，失败返回 nil。
    var jsonObject: Any? {
        guard let data = data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
