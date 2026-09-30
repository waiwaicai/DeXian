import Foundation

/// 书源级变量（Legado 的 source.getVariable / setVariable）。
///
/// 与 `VariableStore`（书籍级）不同，这里按**书源**存一份，跨搜索 / 发现 /
/// 阅读全程共享，并且落盘。
///
/// 为什么必须落盘：表单型发现源（七猫 · API、奈飞工厂、听小说APP、米读、
/// 有度中文…）把用户在下拉框里选的值写在 `source.setVariable(...)` 里，
/// 下次求值 `source.getVariable()` 读回来决定「显示哪个频道 / 用哪个接口」。
/// 不持久化的话，用户切完频道退出发现页再进来又被重置成默认值。
final class SourceVariableStore: @unchecked Sendable {

    /// 全进程共享：发现页、搜索页、阅读页各自会新建 SourceEngine，
    /// 但它们读写的是同一份书源变量，必须共用同一个容器。
    static let shared = SourceVariableStore()

    private let lock = NSLock()
    private var values: [String: String]
    private let fileName: String

    /// 落盘队列与待写标记。
    ///
    /// 不能每次 setVariable 都同步写文件：实测听小说APP 的 chapterUrl 规则
    /// **每取一章**就调一次 source.setVariable 缓存签名参数，
    /// 一本两千章的书会写两千次盘 —— 阅读时的卡顿与
    /// 「翻着翻着闪退」有一部分就是这么来的。
    /// 这里改成合并写入：1 秒内的多次改动只落一次盘。
    private let writeQueue = DispatchQueue(label: "com.dexian.sourceVariables.write")
    private var pendingWrite = false

    init(fileName: String = "sourceVariables.json") {
        self.fileName = fileName
        values = FileStorage.load([String: String].self, from: fileName) ?? [:]
    }

    subscript(sourceId: String) -> String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return values[sourceId]
        }
        set {
            lock.lock()
            if let newValue, !newValue.isEmpty {
                values[sourceId] = newValue
            } else {
                values.removeValue(forKey: sourceId)
            }
            lock.unlock()
            scheduleWrite()
        }
    }

    var snapshot: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func flushPendingWrites() {
        let snapshot = self.snapshot
        FileStorage.save(snapshot, to: fileName)
    }

    /// 合并写入：同一秒内的多次改动只落一次盘。
    private func scheduleWrite() {
        lock.lock()
        if pendingWrite {
            lock.unlock()
            return
        }
        pendingWrite = true
        lock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            // 合并窗口：期间的改动都累积在 values 里
            Thread.sleep(forTimeInterval: 1.0)
            let snapshot = self.snapshot
            FileStorage.save(snapshot, to: self.fileName)
            self.lock.lock()
            self.pendingWrite = false
            self.lock.unlock()
        }
    }
}
