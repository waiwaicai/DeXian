import Foundation
import Darwin

/// 崩溃与「被杀」现场记录。
///
/// 之前排查闪退靠的是「你说症状、我猜原因」，来回很多轮都没定位到根上。
/// 这里补两类现场，下次在手机上闪退后，进「我的 → 调试日志」就能看到原因：
///
/// 1. **信号 / 未捕获异常**（数组越界、强制解包 nil、重复 id 等运行时陷阱，
///    以及段错误）会带上调用栈，直接指出崩在哪一行；
/// 2. **被系统杀掉（内存超限 Jetsam / 主线程卡死被看门狗杀）** 不产生任何崩溃报告，
///    改用「运行标记」推断：启动时写上标记，正常退出才清掉；
///    下次启动若发现标记还在，就说明上次是被强杀的，并附上当时的日志。
///
/// 信号处理器是特殊环境：**不能加锁、不能分配内存**，否则很可能
/// 正好死锁在崩溃线程持有的 malloc/锁 上 —— 那样进程既不崩也不退，只能强杀。
/// 因此这里：
/// - 启动时预先把文件描述符和全部要写的文本准备好；
/// - 处理器里只用 `write` 与 `backtrace_symbols_fd` 这两个官方保证
///   异步信号安全的接口，全程零分配、零加锁。
enum CrashReporter {

    private static let reportName = "last-crash.txt"
    private static let markerName = "running.marker"

    // MARK: 信号安全区（启动时分配，处理器里只读）

    private static let bufferCapacity = 24 * 256
    private static let prefixCount = 8

    /// 崩溃前日志的线性缓冲。用完即从头覆盖，不做环形回绕 ——
    /// 环形结构在处理器里需要拼两段，容易引入分配，得不偿失。
    fileprivate static let logBuffer: UnsafeMutablePointer<UInt8> = {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferCapacity)
        pointer.initialize(repeating: 0, count: bufferCapacity)
        return pointer
    }()

    fileprivate static var logUsed = 0
    fileprivate static var descriptor: Int32 = -1
    /// 调用栈帧缓冲：同样在启动时预分配。
    /// 信号处理器里不能出现任何 `Array(repeating:count:)` —— 那是一次堆分配。
    private static let frameCapacity = 64
    fileprivate static let frames: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let pointer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: frameCapacity)
        pointer.initialize(repeating: nil, count: frameCapacity)
        return pointer
    }()

    /// 每个信号的说明文本（C 字符串指针），启动时填好。
    /// 用下标直接取，处理器里不需要任何字符串拼接。
    fileprivate static let prefixes: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
        let pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: prefixCount)
        pointer.initialize(repeating: nil, count: prefixCount)
        return pointer
    }()

    /// 上次运行留下的崩溃报告（启动时读出）
    private(set) static var lastReport: String?

    // MARK: 生命周期

    /// 在 App 启动最早期调用。
    static func install() {
        // 先把信号安全区全部就绪：处理器绝不能触发惰性初始化（那要分配内存）。
        _ = logBuffer
        _ = prefixes
        _ = logUsed
        _ = descriptor
        _ = frames
        preparePrefixes()

        // 顺序很重要：先把上一次的现场读进内存，再拿描述符。
        // open(O_TRUNC) 会立刻清空文件，先开文件就等于把上次的崩溃报告删掉了，
        // detectPreviousKill() 只能读到空内容 —— 现场记录会静默失效。
        detectPreviousKill()

        let file = FileStorage.url(reportName)
        descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        // 必须传「文件级函数」而不是内联闭包：
        // 这个参数的形参是 C 函数指针（@convention(c)），
        // 内联闭包里引用 CrashReporter 的静态成员会被判定成捕获上下文，
        // 直接编译失败：
        // "a C function pointer cannot be formed from a closure that captures context"
        NSSetUncaughtExceptionHandler(dexianHandleUncaughtException)

        for number in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(number, handleSignal)
        }
    }

    /// 标记本次运行开始。
    static func beginSession() {
        try? "running".write(to: FileStorage.url(markerName), atomically: true, encoding: .utf8)
    }

    /// 正常退出：清掉标记，下次启动就不会误报成「被强杀」。
    static func endSession() {
        try? FileManager.default.removeItem(at: FileStorage.url(markerName))
    }

    /// 写入镜像用的锁。
    ///
    /// 这里可以加锁：log 从多个线程写入（搜索并发、图片后台解码），
    /// 不锁会把 logUsed 踩乱。信号处理器**只读不锁**，
    /// 所以即使崩溃线程正持有这把锁，也不会把处理器卡死。
    private static let mirrorLock = NSLock()

    /// 把一行日志镜像进崩溃现场缓冲。
    static func record(_ text: String) {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        for byte in text.utf8 {
            if logUsed >= bufferCapacity { logUsed = 0 }
            logBuffer[logUsed] = byte
            logUsed += 1
        }
        if logUsed >= bufferCapacity { logUsed = 0 }
        logBuffer[logUsed] = newlineByte
        logUsed += 1
    }

    static func clear() {
        lastReport = nil
        try? FileManager.default.removeItem(at: FileStorage.url(reportName))
    }

    // MARK: 普通上下文辅助

    fileprivate static func newline() -> String {
        "\n"
    }

    fileprivate static func loadReport() -> String? {
        guard let text = try? String(contentsOf: FileStorage.url(reportName), encoding: .utf8) else {
            return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 上一次运行是被强杀的？
    ///
    /// 内存超限（Jetsam）与看门狗杀进程都不生成崩溃报告，
    /// 只能靠「运行标记没被清掉」判断，并回带崩溃前最后的日志。
    private static func detectPreviousKill() {
        if let report = loadReport() {
            lastReport = report
            return
        }
        let marker = FileStorage.url(markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        var text = "上次运行被系统强制结束（没有崩溃报告）"
        text += newline() + "常见原因：内存超限被 Jetsam 杀掉，或主线程卡死被看门狗杀掉。"
        text += newline() + newline() + "崩溃前日志:" + newline() + mirroredLog()
        lastReport = text
    }

    fileprivate static func mirroredLog() -> String {
        guard logUsed > 0 else { return "(无)" }
        let bytes = UnsafeBufferPointer(start: logBuffer, count: logUsed)
        let text = String(decoding: bytes, as: UTF8.self)
        return text.isEmpty ? "(无)" : text
    }

    /// 普通上下文里补写内容（未捕获异常用）。
    fileprivate static func append(_ text: String) {
        guard descriptor >= 0 else { return }
        writeAll(text)
    }

    private static func writeAll(_ text: String) {
        var bytes = Array(text.utf8)
        bytes.append(newlineByte)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, base + written, buffer.count - written)
                if result <= 0 { break }
                written += result
            }
        }
    }

    // MARK: 信号安全区

    /// 换行字节（0x0A）。用 UInt8 常量而不是 `UInt8(ascii:)`，
    /// 后者要的是 `Unicode.Scalar`，传 Character 编译不过。
    fileprivate static let newlineByte: UInt8 = 0x0A

    /// 启动时把每个信号的说明文本准备好。
    private static func preparePrefixes() {
        let table: [Int32: String] = [
            SIGABRT: "信号 SIGABRT：Swift 运行时陷阱（数组越界 / 强制解包 nil / 重复 id）"
                + newline() + "崩溃前日志:" + newline(),
            SIGSEGV: "信号 SIGSEGV：段错误（访问了非法内存）",
            SIGBUS: "信号 SIGBUS：总线错误",
            SIGILL: "信号 SIGILL：非法指令",
            SIGFPE: "信号 SIGFPE：算术异常",
            SIGTRAP: "信号 SIGTRAP：断点陷阱"
        ]
        for (number, text) in table {
            guard let raw = strdup(text), let index = prefixIndex(number) else { continue }
            prefixes[index] = raw
        }
    }

    /// 信号号 -> 前缀表下标（纯计算，无分配）。
    fileprivate static func prefixIndex(_ number: Int32) -> Int? {
        switch number {
        case SIGABRT: return 0
        case SIGSEGV: return 1
        case SIGBUS: return 2
        case SIGILL: return 3
        case SIGFPE: return 4
        case SIGTRAP: return 5
        default: return nil
        }
    }

    /// 信号处理器：只调用官方保证异步信号安全的接口。
    fileprivate static let handleSignal: @convention(c) (Int32) -> Void = { number in
        guard descriptor >= 0 else { _exit(128 + number) }

        // 1) 先写信号说明 —— 这一段最不能丢
        if let index = prefixIndex(number), let prefix = prefixes[index] {
            _ = Darwin.write(descriptor, prefix, strlen(prefix))
        }

        // 2) 写崩溃前日志：整块内存直接落盘，不做任何转换
        if logUsed > 0 {
            _ = Darwin.write(descriptor, logBuffer, logUsed)
        }

        // 3) 写调用栈：backtrace_symbols_fd 直接写 fd，零分配
        let count = backtrace(frames, Int32(frameCapacity))
        if count > 0 {
            backtrace_symbols_fd(frames, count, descriptor)
        }

        // 4) 恢复默认处理并重新抛出，保证系统原生崩溃报告依然生成
        signal(number, SIG_DFL)
        raise(number)
        _exit(128 + number)
    }
}

/// 未捕获异常处理器。
///
/// 特意放在文件作用域而不是写在 `install()` 里：
/// `NSSetUncaughtExceptionHandler` 要的是 C 函数指针，
/// 只有真正的顶层函数才能形成指针；写成闭包即使不引用任何局部变量，
/// 只要引用了 `CrashReporter` 的静态成员就会被 Swift 判定为捕获上下文。
///
/// 这里仍是普通上下文（不是信号处理器），可以自由使用 Foundation。
private func dexianHandleUncaughtException(_ exception: NSException) {
    var text = "未捕获异常: " + exception.name.rawValue
    text += CrashReporter.newline() + "原因: " + (exception.reason ?? "(无)")
    text += CrashReporter.newline() + CrashReporter.newline()
    text += "崩溃前日志:" + CrashReporter.newline() + CrashReporter.mirroredLog()
    text += CrashReporter.newline() + CrashReporter.newline()
    text += "调用栈:" + CrashReporter.newline()
    text += exception.callStackSymbols.joined(separator: CrashReporter.newline())
    CrashReporter.append(text)
}
