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
        // 同时在崩溃报告里留一份现场：闪退时内存里的这条环形缓冲会一起消失，
        // 只有预先镜像到信号安全区，崩溃报告才能带上「崩之前正在做什么」。
        CrashReporter.record(category + ": " + message)
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

    /// 导出成 TXT：日志面板可另存，不再只能复制到剪贴板。
    static func exportText() -> String {
        let entries = recent
        var lines: [String] = []
        lines.append("得闲 DeXian 调试日志")
        lines.append("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
        lines.append("构建 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))
        lines.append("导出时间 " + Date().formatted(date: .numeric, time: .standard))
        lines.append("")
        for entry in entries {
            let time = entry.date.formatted(date: .omitted, time: .standard)
            lines.append("[" + time + "] [" + entry.category + "] " + entry.message)
        }
        let crash = CrashReporter.lastReport
        if let crash, !crash.isEmpty {
            lines.append("")
            lines.append("=== 上次闪退现场 ===")
            lines.append(crash)
        }
        return lines.joined(separator: "\n")
    }
}
