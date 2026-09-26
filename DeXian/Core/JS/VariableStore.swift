import Foundation

/// 书籍级共享变量（对应 Legado 的 book.variable）。
///
/// 书源常用 java.put('bookId', result) 在搜索阶段存值、目录阶段取值，
/// 这些变量必须跨「搜索 / 详情 / 目录 / 正文」多次 JS 求值共享，
/// 因此用引用类型在同一个 SourceEngine 内传递，并可持久化到书架。
final class VariableStore {
    private var values: [String: String]
    private let lock = NSLock()

    init(_ initial: [String: String] = [:]) {
        values = initial
    }

    subscript(key: String) -> String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if let newValue { values[key] = newValue } else { values.removeValue(forKey: key) }
        }
    }

    var snapshot: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
