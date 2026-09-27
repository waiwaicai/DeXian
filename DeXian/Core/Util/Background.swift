import Foundation

/// 后台执行工具：把耗时的纯计算移出主线程。
///
/// 项目里的规则引擎大部分是 struct / static 且无共享状态，
/// 用 detached task 执行既能避免卡住界面，也不会引入数据竞争。
enum Background {

    /// 在后台线程执行一段同步代码并返回结果。
    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// 在后台线程执行可能抛错的同步代码。
    static func runThrowing<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

/// 线程安全的取值盒子：用于跨线程回传结果（信号量 + 回调场景）。
final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    var current: T {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
