import Foundation
import OSLog

enum Log {
    private static let subsystem = "com.dexian.reader"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let rule = Logger(subsystem: subsystem, category: "rule")
    static let js = Logger(subsystem: subsystem, category: "js")

    /// 调试面板里展示的最近日志（内存环形缓冲）。
    private static let lock = NSLock()
    private static var buffer: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let category: String
        let message: String
    }

    static func debugLog(_ category: String, _ message: String) {
        lock.lock()
        buffer.append(Entry(category: category, message: message))
        if buffer.count > 400 { buffer.removeFirst(buffer.count - 400) }
        lock.unlock()
    }

    static var recent: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    static func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}
