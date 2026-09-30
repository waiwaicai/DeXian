import Foundation
import CoreFoundation
import JavaScriptCore
import CryptoKit

/// 书源 JavaScript 运行时。
///
/// 对齐 Legado 的 Rhino 环境：暴露 java / source / book / chapter / cookie / cache
/// 以及 result / baseUrl / src / title / key / page 等变量。
/// JavaScriptCore 不是线程安全的，这里用递归锁串行化访问。
final class JSEngine {

    /// 宿主回调：把规则求值能力交回给规则引擎（java.getString 等）
    struct Host {
        var sourceKey: String = ""
        var sourceName: String = ""
        /// 书源入口地址（对应 Legado 的 source.bookSourceUrl / source.key）。
        var sourceUrl: String = ""
        /// 书源备注：规则用 `eval(String(source.bookSourceComment))` 解出 helper 函数再调用。
        /// 语料实测 40 篇书源把公共函数写在注释里，缺失时就是
        /// "Can't find variable: traditionalToSimplified" / "Can't find variable: decode"。
        var sourceComment: String = ""
        /// 变量说明：部分书源在脚本里读它做展示。
        var variableComment: String = ""
        /// 书源级请求头（JSON 文本），脚本会读它自行拼请求。
        var sourceHeader: String = ""
        /// 登录地址：脚本里会 eval(String(source.loginUrl))
        var loginUrl: String = ""
        var concurrentRate: String = ""
        var baseUrl: String = ""
        var headers: [String: String] = [:]
        var resolveString: ((String, Any?, Bool) -> String)?
        var resolveStringList: ((String, Any?, Bool) -> [String])?
        var setContent: ((Any?) -> Void)?
        var document: HTMLNode?
        var bookInfo: [String: String] = [:]
        var chapterInfo: [String: String] = [:]
        var title: String = ""
        /// 跨步骤共享的书籍级变量
        var variables = VariableStore()
        /// 书籍地址 / 类型 / 阅读进度。
        ///
        /// 书源脚本直接读 `book.durChapterIndex`（880 个源）、
        /// `book.totalChapterNum`（619 个源）、`book.canUpdate`（362 个源），
        /// 拿它们做「当前章是否 VIP」「目录是否刷新」这类判断，
        /// 缺失时是 undefined 参与比较 —— 判断恒为 false，正文整段取不到。
        var bookUrl: String = ""
        var bookType: Int = 0
        var durChapterIndex: Int = 0
        var durChapterTitle: String = ""
        var totalChapterNum: Int = 0
        var canUpdate: Bool = true
        var customIntro: String = ""
        var latestChapterTitle: String = ""
        var bookStatus: String = ""
        var reverseToc: Bool = false
        var useReplaceRule: Bool = true
        /// 书源元信息的**全量**透传。
        ///
        /// 书源脚本直接读自己声明里的字段：
        /// `if (source.bookSourceType == '3')`（82 个源）、
        /// `timeFormat(source.lastUpdateTime)`（59 个源）、
        /// `String(source.exploreUrl).match(/let banben=.../)`（44 个源）、
        /// `source.ruleExplore.author`（13 个源）。
        /// 逐个硬编码既写不全、也会随书源格式演进而失效，
        /// 因此这里整体透传，缺什么补什么。
        var sourceMeta: [String: Any] = [:]
        /// 书架序号（Legado 的 book.order）：源写
        /// `if (book && book.order != 0 && reading == '1')` 决定走不走书架同步分支。
        var bookOrder: Int = 0
        /// 脚本要求「把这本书加进书架 / 重新登录 / 写剪贴板」时回调宿主。
        var onAddBook: ((String) -> Void)?
        var onClipboard: ((String) -> Void)?
        var onBookTypeChanged: ((Int) -> Void)?
        var onReverseTocChanged: ((Bool) -> Void)?
    }

    let context: JSContext?
    private let lock = NSRecursiveLock()

    /// 书源级变量（Legado 的 source.getVariable / setVariable）。
    ///
    /// 由 SourceEngine 在构造时注入、求值后取回并落盘，因此不能是 private：
    /// 表单型发现源「切换频道 / 切换接口」正是靠它跨次保留选择。
    var sourceVariable: String = ""
    /// 登录相关状态与规则级缓存。
    ///
    /// 这三个**不是 private**：JSEngineCompat.swift 里的兼容层需要读写它们
    /// （java.upLoginData 落账号、java.importScript / cacheFile 做缓存）。
    /// Swift 的 private 是文件级作用域，跨文件访问会被编译器拒绝。
    var loginHeader: String?
    var loginInfo: [String: String] = [:]
    var cache: [String: String] = [:]

    var host: Host
    var key: String = ""
    var page: Int = 1
    var result: Any?
    var src: String = ""

    /// 普通 UA 与 WebView UA。
    ///
    /// 书源用 `java.getUserAgent() === java.getWebViewUA()` 判断自己是否
    /// 跑在「源阅」上（实测 14 个源），两者必须**不同**，否则会走错分支。
    /// 这里让 WebView UA 带上机型后缀，与 getUserAgent 明确区分开。
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let webViewUserAgent = userAgent + " DeXian/1.0"

    /// 最近一次求值触发的未捕获异常原文（由 `context.exceptionHandler` 写入）。
    ///
    /// JavaScriptCore 装了 exceptionHandler 之后不再写 `context.exception`，
    /// 求值循环只能从这里取报错文案，否则无法判断「是不是语法错误」，
    /// 换包装重试与归一化兜底会一并失效。
    /// 读写都在 `evaluateOnQueue` 的 `lock` 保护范围内，且每次求值前清空。
    private var pendingExceptionMessage: String?

    /// 每个引擎一个虚拟机，但**必须能被释放**。
    ///
    /// 之前这里存在一个强引用环：注册给 JS 的每个 block 都强捕获了
    /// JSContext，而这些 block 又存在同一个 JSContext 的全局对象上
    /// （java / source / cache …），于是
    /// `JSContext → java → block → JSContext` 自锁，JSContext 永不释放，
    /// 连带它持有的 JSVirtualMachine 也永不释放。
    /// 搜索每跑一个书源就泄漏一整个虚拟机，搜到近百个源时
    /// JavaScriptCore 内存分配失败走 CRASH() → abort，
    /// 表现为 SIGABRT、调用栈全是 JavaScriptCore 帧，
    /// 且稳定地「搜到某个数量就闪退」。
    /// 现在所有 block 一律 [weak context] 捕获，环被打断，
    /// 引擎随书源任务结束即时释放（在飞的最多 concurrentLimit 个）。

    init(host: Host = Host()) {
        self.host = host
        context = JSContext(virtualMachine: JSVirtualMachine())
        setup()
    }

    // MARK: 求值

    /// 求值脚本。返回 String / Int64 / Double / Bool / JSON 对象。
    /// JS 求值专用线程。
    ///
    /// 书源脚本里会有 `java.ajax` 这类同步网络调用，必须在求值期间阻塞。
    /// 如果直接在 Swift 并发协作线程池上求值，阻塞会占满池线程
    /// （iPhone 通常只有 6 个左右），后续 Task 拿不到线程就会整页卡死，
    /// 最终被系统看门狗强杀。这里统一把求值放到专用线程串行执行。
    /// 用 specific 标记队列身份：脚本内部会回调 java.getString，
    /// 进而重入 evaluate。若直接对串行队列 sync 会自锁死，这里做可重入判断。
    private static let evaluationQueueKey = DispatchSpecificKey<UInt8>()
    private static let evaluationQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.dexian.js.evaluate", attributes: .concurrent)
        queue.setSpecific(key: evaluationQueueKey, value: 1)
        return queue
    }()

    /// 供需要「等待用户操作」的脚本调用（如 java.startBrowserAwait）。
    /// 由外部注入：运行在后台线程，内部自行切主线程弹出界面。
    var awaitUserAction: ((String, String) -> String)?

    /// 表单型发现源的按钮脚本会调用 `java.searchBook(keyword, source)`。
    /// 实测 5 个源（吉站漫画 / 听小说APP / 奈飞工厂 / 终极全栖接口聚合 / 七猫·API）
    /// 把「🔍搜索」按钮写成 `java.searchBook(infoMap['关键字'], source)`。
    /// 宿主把关键词接回界面，由搜索页跑一次全局搜索 —— 否则这个按钮点下去
    /// 只会静默走 noop，用户看到的就是「右上角加号点了没用」。
    var onSearchBook: ((String) -> Void)?

    /// 表单控件变化时脚本调用 `java.refreshExplore()` 要求重新求值发现页。
    var onRefreshExplore: (() -> Void)?

    /// 脚本调用 `java.toast / longToast` 时的用户提示。
    var onToast: ((String) -> Void)?

    /// 脚本调用 `java.upLoginData(...)` / `source.putLoginInfo(...)` 时，
    /// 把新的登录信息交回宿主落盘。
    ///
    /// 实测 75 个源依赖它做「登录后保存账号」，其中晋江 / 起点 / 哔哩哔哩
    /// 等 9 个源把它写在登录流程的收尾处。缺失时是
    /// `undefined is not a function`，整段登录脚本中断 ——
    /// 用户看到的是「授权码/账号明明填对了，还提示未登录」。
    var onLoginInfoChanged: (([String: String]) -> Void)?

    /// 脚本调用 `java.upLoginData(无参)` / `source.login()` 时要求弹出登录界面。
    var onRequestLogin: (() -> Void)?

    /// 脚本调用 `java.refreshTocUrl()` / `refreshBookUrl()` / `refreshBookInfo()` /
    /// `refreshContent()` / `reGetBook()` / `refreshBookToc()` 等刷新类 API 时的通知。
    ///
    /// 实测 733 个源调用 `refreshTocUrl`，212 个源调用 `refreshBookUrl`。
    /// 这些 API 的语义是「目录地址/书籍地址已变，请重新拉取」；
    /// 缺了就是 `undefined is not a function`，切换线路后目录永远刷不出来。
    var onRefreshRequest: ((String) -> Void)?

    /// 本次求值对应的响应对象（供 `java.getResponse()` / `java.getHeaderMap()` 读取）。
    ///
    /// 只在单次求值期间有效，由宿主在拿到响应后注入、求值结束后清空。
    var lastResponse: HTTPResponse?

    /// 脚本调用 `java.openVideoPlayer(url, title, float)` 时把直链交回界面播放。
    var onOpenVideo: ((String, String) -> Void)?

    /// 脚本调用 `source.setVariable(...)` 时把新值交给宿主持久化。
    var onVariableChanged: ((String) -> Void)?

    /// 书籍级可变状态。
    ///
    /// 脚本会**写** `book.bookUrl` / `book.customIntro` / `book.type`，
    /// 宿主求值结束后需要把这些改动取回落盘（否则「改书名」「改地址」
    /// 这类操作只在本次求值内有效）。
    var bookMutation: BookMutation = BookMutation()

    /// 书籍级可变字段的回写载体。
    struct BookMutation {
        var bookUrl: String?
        var customIntro: String?
        var type: Int?
        var reverseToc: Bool?
        var canUpdate: Bool?
        var variable: String?
    }

    /// 在 JS 求值内部同步等待用户完成网页操作（验证码 / 登录）。
    ///
    /// 脚本运行在专用线程上，这里用信号量阻塞不会影响协作线程池。
    func waitForUserAction(url: String, title: String) -> String {
        guard let awaitUserAction else { return "" }
        return awaitUserAction(url, title)
    }

    /// 求值脚本。
    ///
    /// `resultOverride` 仅对**本次**求值生效，用于 loginCheckJs ——
    /// 那种脚本里的 `result` 是**响应对象**而不是规则链上一步的值
    /// （对齐 Legado 的 `evalJS(loginCheckJs, strResponse)`）。
    /// 用参数传递而非成员变量：脚本内部还会调 java.getString 之类重入求值，
    /// 成员变量会被那些嵌套求值误消费，参数则天然只作用于当前这一次。
    func evaluate(_ script: String, resultOverride: JSValue? = nil) -> Any? {
        // 已在专用线程上（脚本回调重入）：直接求值，避免对同一队列 sync 死锁
        if DispatchQueue.getSpecific(key: JSEngine.evaluationQueueKey) != nil {
            return evaluateOnQueue(script, resultOverride: resultOverride)
        }
        var output: Any?
        JSEngine.evaluationQueue.sync {
            output = evaluateOnQueue(script, resultOverride: resultOverride)
        }
        return output
    }

    private func evaluateOnQueue(_ script: String, resultOverride: JSValue? = nil) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return nil }
        let injectedResult = resultOverride

        // 每次求值都在独立的 autorelease pool 里跑。
        //
        // JavaScriptCore 的 JSValue / 异常对象都是 autorelease 的 Objective-C 对象：
        // 一次搜索要跑上百个书源、每个源评估几十条规则，产生的临时对象以万计。
        // Swift 并发任务跑在协作线程池上，**不自带 autorelease pool**，
        // 这些临时对象会一直挂在线程上直到线程被回收 ——
        // 表现就是搜索越跑内存越高，到某个固定数量后进程被系统一次性清掉。
        // 求值返回值经 swiftValue 已转成纯 Swift 类型（String / Int64 / Array / Dictionary），
        // 不依赖 pool 存活，因此在池内返回是安全的。
        return autoreleasepool {
            context.setObject(key, forKeyedSubscript: "key" as NSString)
            context.setObject(page, forKeyedSubscript: "page" as NSString)
            context.setObject(host.baseUrl, forKeyedSubscript: "baseUrl" as NSString)
            context.setObject(src, forKeyedSubscript: "src" as NSString)
            context.setObject(host.title, forKeyedSubscript: "title" as NSString)
            // 无条件注入 result。
            //
            // 原实现只在 result != nil 时才定义全局 result，于是「上一段规则没有输出」
            // 时脚本里会出现 ReferenceError: Can't find variable: result。
            // 书源大量依赖 result（实测 2100 处），必须保证它始终存在；
            // 没有值就注入 null，交给脚本自己的判空逻辑处理。
            //
            // result 可能是 HTMLNode（pure Swift class）或含它的容器：
            // 直接交给 JavaScriptCore 会在 ObjC 桥接层反射它的内存布局，
            // 触发 Swift 运行时陷阱（SIGABRT）。必须先净化为 JSC 认识的形态。
            if let injectedResult {
                context.setObject(injectedResult, forKeyedSubscript: "result" as NSString)
            } else {
                context.setObject(bridgeForInjection(result), forKeyedSubscript: "result" as NSString)
            }

            // 脚本一律包进一个块再求值。
            //
            // 书源里有大量脚本在顶层写 `let/const/class`（实测 136 段、
            // 286 个不同变量名，其中 `txt`/`key`/`name`/`list`/`page`
            // 等高频名字反复出现）。这些声明一旦落进**全局词法环境**，
            // 同一条规则第二次执行就是
            // `SyntaxError: Can't create duplicate variable: 'txt'`，
            // 规则静默作废 —— 表现是「有的书能看、再搜一次就空白」。
            // 包一层 `{ … }` 后声明只活在这个块里，重复求值不再冲突；
            // 而 `var` / 函数声明 / eval 出来的 helper 仍按 Annex B 提升到全局，
            // 书源依赖的 `eval(String(source.bookSourceComment))` 不受影响。
            var lastMessage = ""
            var candidates = JSEngine.scriptCandidates(script)
            // 归一化候选**惰性追加**：只有常规形态全部因语法错误失败后才计算。
            // 惰性是有意的 —— 归一化要逐字符扫一遍脚本，而规则求值极其频繁
            // （每个字段、每章都会跑），无条件预计算等于给每次求值都加一笔开销，
            // 却对 99% 语法正确的脚本毫无用处。
            var appendedNormalized = false
            var index = 0
            while index < candidates.count {
                let candidate = candidates[index]
                context.exception = nil
                pendingExceptionMessage = nil
                let value = context.evaluateScript(candidate)
                // 异常有两个来源，缺一不可：
                //
                // 1. `context.exception` —— 未安装 exceptionHandler 时的常规通道；
                // 2. `pendingExceptionMessage` —— **本引擎实际走的那条**。
                //
                // JavaScriptCore 一旦设置了 exceptionHandler，未捕获异常就只交给
                // handler，**不再写入 `context.exception`**。本引擎在 setup() 里装了
                // 这个 handler（用于把未捕获异常写进调试日志），于是
                // `context.exception` 恒为 nil，只看它等于**把每一次语法错误都当成
                // 求值成功**：下面的 guard 判定为 nil 直接 return，既不换包装重试、
                // 也不走归一化兜底。
                //
                // 实测（真机 iOS 27 + 单元测试）：裸解构箭头脚本
                //     [[1,2],[3,4]].map([a,b]=>{ … }); out.join(',')
                // 的块形态与函数形态各抛一次
                //     SyntaxError: Unexpected token '=>'. Expected ')' to end an argument list.
                // handler 日志里两条都在，但 context.exception 始终是 nil，
                // 循环在第一轮就返回 undefined，最终静默返回空串。
                var thrownText: String?
                if let exception = context.exception {
                    thrownText = exception.toString() ?? ""
                } else {
                    thrownText = pendingExceptionMessage
                }
                context.exception = nil
                pendingExceptionMessage = nil
                guard let thrownText else {
                    return JSEngine.swiftValue(value)
                }
                lastMessage = thrownText
                // 只有**语法错误**才允许换一种包装重试：语法错误阶段一行都没执行，
                // 重试没有副作用。运行期异常可能已经发过网络请求，
                // 再跑一次会把请求翻倍，必须直接放弃。
                let isSyntaxError = lastMessage.contains("SyntaxError")
                    || lastMessage.contains("Illegal return")
                    // JavaScriptCore 对顶层 return 的报错原文是
                    // "Return statements are only valid inside functions."，
                    // 既不含 "SyntaxError" 也不含 "Illegal return"。
                    // 只匹配前两种写法时，这条判定会失败并直接放弃，
                    // 于是「顶层 return」的脚本永远拿到空串。
                    || lastMessage.contains("Return statements are only valid inside functions")
                // 常规形态还有剩余且确认是语法错误：换下一种包装重试。
                if isSyntaxError, index + 1 < candidates.count {
                    index += 1
                    continue
                }
                // 归一化兜底：**不依赖报错文案**。
                //
                // 归一化只有在脚本里真的存在「裸解构箭头参数」时才返回候选，
                // 而那种写法本身就是语法错误，所以这里不会把运行期异常
                // 误重试成一次额外请求 —— 那类脚本归一化不产生任何改动，
                // 与上面「运行期异常必须直接放弃」的约定并不冲突。
                //
                // 之所以不能只认 "SyntaxError" 文案：JavaScriptCore 对这类
                // 语法错误的原文是 "Malformed arrow function parameter list"，
                // 既不含 "SyntaxError" 也不含 "Illegal return"，判定必然失败，
                // 归一化就永远用不上 —— 修的是：
                //     arr.map([title, b] => { … })
                // Rhino 宽容，标准 JS 引擎（JSC / V8）直接报错、整段不执行。
                // 实测新书源里 30 段脚本栽在这里，表现是那些源的发现页/目录全空。
                if !appendedNormalized {
                    appendedNormalized = true
                    // 记住追加起点：追加后必须**直接跳到第一个归一化候选**。
                    // 若写成 index += 1，当 index 还停在常规形态中间时
                    // 会落到另一个常规形态上 —— 它必然报同样的语法错误，
                    // 而 appendedNormalized 已为真，循环随即退出，
                    // 归一化候选根本没机会执行，修复等于没生效。
                    let firstNormalized = candidates.count
                    let extra = JSEngine.normalizedCandidates(script)
                    if !extra.isEmpty {
                        candidates.append(contentsOf: extra)
                        index = firstNormalized
                        continue
                    }
                }
                break
            }
            if !lastMessage.isEmpty {
                Log.debugLog("JS", "异常: " + lastMessage + " | 脚本: " + String(script.prefix(160)))
            }
            return nil
        }
    }

    /// 把要写进 JS 全局 `result` 的值净化成「脚本一定认识」的形态。
    ///
    /// 与 `JSEngine.jsSafeValue` 的唯一区别：HTMLNode 不再被文本化，
    /// 而是包成带 select / attr / text / toArray 的元素对象。
    ///
    /// 书源里写 `result.select(...)` / `result.toArray()` 的地方，
    /// 指望 `result` 就是 jsoup 的元素（对齐 Legado 的 getElements 语义）。
    /// 文本化后这些调用一律是 undefined is not a function。
    /// 而 HTMLNode 是纯 Swift 类型，直接交给 JavaScriptCore 会在桥接层
    /// 触发 Swift 运行时陷阱（SIGABRT），所以必须走包装。
    private func bridgeForInjection(_ value: Any?) -> Any {
        guard let context else { return JSEngine.jsSafeValue(value) }
        // 只处理顶层：规则链把节点交给 JS 时，形态必然是单个节点或节点数组。
        // 容器（字典 / 数组里混着节点）仍走 jsSafeValue 文本化 ——
        // 那种形态只在测试里构造，且节点在容器里本来也只能靠文本传递。
        if let node = value as? HTMLNode { return wrapElement(node, in: context) }
        if let nodes = value as? [HTMLNode] {
            return JSEngine.makeElementListValue(nodes, engine: self, in: context)
        }
        return JSEngine.jsSafeValue(value)
    }

    /// 把一段书源脚本包成可安全反复求值的形式。
    ///
    /// 见 `evaluateOnQueue` 里对块包装的说明：包一层块是为了让顶层
    /// `let/const/class` 不落进全局词法环境，从而支持同一条规则反复求值。
    ///
    /// 少数脚本在顶层写 `return`（实测 4 段）。这在脚本形态下是语法错误，
    /// 因此额外提供一个函数包裹形态作为后备；只有真的报了语法错误才会用到它。
    static func scriptCandidates(_ script: String) -> [String] {
        let body = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [script] }
        let block = "{\n" + script + "\n}"
        let wrapped = "(function(){\n" + script + "\n})()"
        // 顶层 return 的脚本在块形态下是**语法错误**，函数形态才是唯一解，
        // 因此放到首位，省掉一次注定失败的求值。
        if hasTopLevelReturn(script) { return [wrapped, block] }
        return [block, wrapped]
    }

    /// 语法错误专用：把脚本归一化成标准写法后的候选形态。
    ///
    /// 只在 `evaluateOnQueue` 判定为**语法错误**且常规形态已用尽时才调用，
    /// 正常情况下返回空数组（脚本无需改写），零额外开销。
    ///
    /// 目前归一化只做一件事：给箭头函数的裸解构参数补括号。
    /// 详见 `ScriptNormalizer.normalizeArrowParameters`。
    static func normalizedCandidates(_ script: String) -> [String] {
        guard let normalized = ScriptNormalizer.normalizeArrowParameters(script) else {
            return []
        }
        // 改写后的脚本沿用同样的两种包装，且保持「顶层 return」的优先级。
        return scriptCandidates(normalized)
    }

    /// 脚本里是否存在「函数体之外」的 return。
    ///
    /// 书源脚本在 Legado 里是按**函数体**求值的（Rhino 允许顶层 return），
    /// 而这里为了隔离顶层 `let` 声明会包一层块 —— 块里出现顶层 return
    /// 直接是语法错误。两种形态的容忍度不同，所以必须先把这类脚本挑出来。
    ///
    /// 不要改成「捕获异常后看错误文案」来兜底：JavaScriptCore 的报错原文
    /// 与 V8 / Rhino 都不一致，文案一旦对不上就会静默退化成空串，
    /// 表现是「带 return 的书源整条规则失效」。结构判定与文案无关。
    ///
    /// 扫描时跳过字符串 / 模板串 / 注释 / 正则字面量，只认大括号深度为 0
    /// 处的 `return` 关键字（`function` 体内的 return 深度必然大于 0）。
    static func hasTopLevelReturn(_ script: String) -> Bool {
        let characters = Array(script)
        var index = 0
        var depth = 0
        // 上一个有效字符：用于判断 `/` 是除号还是正则字面量的起始。
        var previous: Character = "\n"

        while index < characters.count {
            let character = characters[index]

            if character == "\"" || character == "'" || character == "`" {
                let quote = character
                index += 1
                while index < characters.count, characters[index] != quote {
                    if characters[index] == "\\" { index += 1 }
                    index += 1
                }
                index += 1
                previous = quote
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            if character == "/", "=(,:![&|?{};+".contains(previous) || previous == "\n" {
                // 正则字面量：只在「上一个有效字符不可能结束一个表达式」时成立。
                var scanning = true
                var inClass = false
                index += 1
                while index < characters.count, scanning {
                    let next = characters[index]
                    if next == "\\" { index += 2; continue }
                    if next == "[" { inClass = true } else if next == "]" { inClass = false }
                    else if next == "/", !inClass { scanning = false }
                    else if next == "\n" { scanning = false }
                    index += 1
                }
                previous = "/"
                continue
            }
            if character == "{" { depth += 1; previous = character; index += 1; continue }
            if character == "}" { depth = max(0, depth - 1); previous = character; index += 1; continue }
            if character.isWhitespace { index += 1; continue }

            if depth == 0, Self.matchesKeyword(characters, at: index, keyword: "return") {
                return true
            }
            previous = character
            index += 1
        }
        return false
    }

    /// 从 `index` 起是否正好是独立的关键字（前后都不能是标识符字符）。
    private static func matchesKeyword(_ characters: [Character], at index: Int, keyword: String) -> Bool {
        let target = Array(keyword)
        guard index + target.count <= characters.count else { return false }
        for offset in 0..<target.count where characters[index + offset] != target[offset] { return false }
        if index > 0, Self.isIdentifierCharacter(characters[index - 1]) { return false }
        let after = index + target.count
        if after < characters.count, Self.isIdentifierCharacter(characters[after]) { return false }
        return true
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    func evaluateString(_ script: String) -> String {
        RuleUtil.asString(evaluate(script)) ?? ""
    }

    /// 把规则求值器的「当前内容」转成 JS 全局 `src` 的字符串形态。
    ///
    /// 对齐 Legado：`bindings["src"] = content`，即**原样**把分析器的 content
    /// 交给脚本。本工程的内容有四种形态，各按书源实际用法映射：
    ///
    /// - `String`：页面 HTML / JSON 文本，原样返回（`JSON.parse(src)` 用它）；
    /// - `HTMLNode`：元素节点。Legado 里内容是 JSoup Element 时 `src` 是
    ///   Element 对象，脚本一般走 `java.getString(rule, src)`。这里给
    ///   **outerHTML** —— 既能被 `JSON.parse` 之外的字符串处理消费，
    ///   也能被 `{@html ...}` 之外的解析复用；给 normalizedText 会丢掉标签，
    ///   实测 `src.match(/href="([^"]+)"/)` 这类写法会整段落空。
    /// - 容器 / 其余：JSON 文本。`datas[java.hexDecodeToString(src)]` 这类
    ///   写法要求 src 是**纯字符串**，直接 String(describing:) 会带上
    ///   Swift 的容器描述（含 `Optional(`），永远解不出来。
    static func ruleContentString(_ content: Any?) -> String {
        guard let content else { return "" }
        if let text = content as? String { return text }
        if let node = content as? HTMLNode { return node.outerHTML }
        if let nodes = content as? [HTMLNode] { return nodes.map { $0.outerHTML }.joined() }
        if let safe = RuleUtil.jsonSafeObject(content),
           JSONSerialization.isValidJSONObject(safe),
           let data = try? JSONSerialization.data(withJSONObject: safe, options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return RuleUtil.asString(content) ?? ""
    }

    /// 求值一次登录检查脚本：脚本里的 `result` 是**响应对象**。
    ///
    /// 对齐 Legado 的 `evalJS(loginCheckJs, strResponse)`。
    /// 书源据此判断限频 / 验证页（实测 33 个源带 loginCheckJs，
    /// 其中 12 个会在此弹人机验证窗口）。
    func evaluateLoginCheck(_ script: String, response: HTTPResponse) -> Any? {
        guard let context else { return nil }
        return evaluate(script, resultOverride: makeResponseObject(response, context: context))
    }

    /// 规则引擎读写书籍级变量
    func variable(named name: String) -> String? {
        host.variables[name]
    }

    func setVariable(_ name: String, value: String) {
        host.variables[name] = value
    }

    /// 注入 jsLib（支持代码片段；URL 形式在当前版本忽略）
    func loadJsLib(_ jsLib: String) {
        let trimmed = jsLib.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return }
        _ = evaluate(trimmed)
    }

    /// 重建全局 infoMap。
    ///
    /// infoMap 在 setup 阶段由兼容层创建，那时 `sourceVariable` 还没注入，
    /// 预填值必然是空的。宿主注入书源变量之后必须重建一次，
    /// 否则表单控件显示的还是默认值，用户上次的选择被无声丢弃。
    func reloadInfoMap() {
        guard context != nil else { return }
        _ = evaluate("if (typeof __dxInfoMap === 'function') { infoMap = __dxInfoMap(); }")
    }

    /// 往全局 infoMap 里写一个控件值（表单 action 执行前调用）。
    func setFormValue(_ name: String, value: String) {
        guard let context, let infoMap = context.objectForKeyedSubscript("infoMap"),
              !infoMap.isUndefined, !infoMap.isNull else { return }
        infoMap.setObject(value, forKeyedSubscript: name as NSString)
    }

    // MARK: 环境搭建

    private func setup() {
        guard let context else { return }
        // 必须弱引用 self：handler 存在 context 上，而 context 由 self 持有，
        // 强引用会形成 `self → context → handler → self` 的自锁，
        // JSContext 与它背后的 JSVirtualMachine 全都无法释放
        // （与上面 setupSource 里那批 block 的成因完全相同）。
        context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? ""
            Log.debugLog("JS", "未捕获异常: " + text)
            // 交给当前正在求值的那次 evaluateOnQueue。
            //
            // 装了 handler 之后 JavaScriptCore 不再写 `context.exception`，
            // 求值循环只能从这里拿报错文案 —— 拿不到就无法判断
            // 「是不是语法错误」，于是换包装重试与归一化兜底全部失效。
            // 写回是线程安全的：evaluateOnQueue 全程持有 `lock`，
            // 而本 handler 只会在该锁内、由同一次求值同步触发。
            self?.pendingExceptionMessage = text
        }
        setupJava(context)
        setupSource(context)
        setupBookChapter(context)
        setupCookie(context)
        setupCache(context)
        // 先补齐 Java 侧扩展 API（CryptoHelper / jsoup / ajaxAll …），
        // 再注入 JS 兼容层 —— 兼容层里的 Packages、CryptoJS、$
        // 都要引用 java.* 与 __dx.* 上的方法，顺序不能反。
        installExtendedJava()
        installCompatJava()
        JSRuntimeBootstrap.install(into: context)
        _ = context.evaluateScript("var console = { log: function(){ java.log(Array.prototype.join.call(arguments,' ')) } };")
    }

    private func setupJava(_ context: JSContext) {
        let java = JSEngine.newObject(in: context)

        let connect: @convention(block) (JSValue) -> JSValue = { [weak self] urlValue in
            guard let self else { return JSValue() }
            return self.connect(url: JSEngine.stringFrom(urlValue), header: nil, method: nil, body: nil)
        }
        java.setObject(connect, forKeyedSubscript: "connect" as NSString)

        let ajax: @convention(block) (JSValue) -> String = { [weak self] urlValue in
            guard let self else { return "" }
            let response = self.connect(url: JSEngine.stringFrom(urlValue), header: nil, method: nil, body: nil)
            return response.objectForKeyedSubscript("__text")?.toString() ?? ""
        }
        java.setObject(ajax, forKeyedSubscript: "ajax" as NSString)

        let post: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak self] urlValue, bodyValue, headerValue in
            guard let self else { return JSValue() }
            return self.connect(url: JSEngine.stringFrom(urlValue),
                                header: headerValue,
                                method: "POST",
                                body: JSEngine.stringFrom(bodyValue))
        }
        java.setObject(post, forKeyedSubscript: "post" as NSString)

        let log: @convention(block) (JSValue) -> Void = { value in
            Log.debugLog("JS", JSEngine.stringFrom(value))
        }
        java.setObject(log, forKeyedSubscript: "log" as NSString)

        // 对应 Legado 的 java.startBrowserAwait：弹出网页让用户过验证 / 登录，
        // 完成后把 Cookie 交回脚本继续执行。
        let startBrowserAwait: @convention(block) (JSValue, JSValue) -> String = { [weak self] urlValue, titleValue in
            guard let self else { return "" }
            let target = JSEngine.stringFrom(urlValue)
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
            let title = JSEngine.stringFrom(titleValue)
            return self.waitForUserAction(url: target, title: title)
        }
        java.setObject(startBrowserAwait, forKeyedSubscript: "startBrowserAwait" as NSString)

        let startBrowser: @convention(block) (JSValue, JSValue) -> Void = { [weak self] urlValue, titleValue in
            guard let self else { return }
            let target = JSEngine.stringFrom(urlValue)
            guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = self.waitForUserAction(url: target, title: JSEngine.stringFrom(titleValue))
        }
        java.setObject(startBrowser, forKeyedSubscript: "startBrowser" as NSString)

        // java.get 有两种重载，必须同时可用（对齐 Legado 的 JsExtensions）：
        //
        // - `java.get('name')` —— 读书源变量（实测 60 处）
        // - `java.get(url, header)` —— 发 HTTP GET，返回响应对象（实测 5 处）
        //
        // 旧实现先注册 HTTP 版本、随后又被变量版本**覆盖**，于是
        // `java.get(su,{}).headers` 一律变成 undefined is not an object。
        // 这里用单个 block 按实参个数分派，两个签名都保住。
        let getOverload: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] first, second in
            guard let self else { return JSValue() }
            if second.isUndefined || second.isNull {
                guard let context = self.context else { return JSValue() }
                let value = self.host.variables[JSEngine.stringFrom(first)]
                return value.map { JSValue(object: $0, in: context) } ?? JSValue()
            }
            return self.connect(url: JSEngine.stringFrom(first), header: second, method: "GET", body: nil)
        }
        java.setObject(getOverload, forKeyedSubscript: "get" as NSString)

        let putVariable: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.host.variables[name] = JSEngine.stringFrom(value)
        }
        java.setObject(putVariable, forKeyedSubscript: "put" as NSString)

        let md5: @convention(block) (JSValue) -> String = { value in
            Crypto.md5(JSEngine.stringFrom(value))
        }
        java.setObject(md5, forKeyedSubscript: "md5Encode" as NSString)

        let md516: @convention(block) (JSValue) -> String = { value in
            String(Crypto.md5(JSEngine.stringFrom(value)).prefix(16))
        }
        java.setObject(md516, forKeyedSubscript: "md5Encode16" as NSString)

        let base64Encode: @convention(block) (JSValue) -> String = { value in
            Data(JSEngine.stringFrom(value).utf8).base64EncodedString()
        }
        java.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)

        let base64Decode: @convention(block) (JSValue) -> String = { value in
            let text = JSEngine.stringFrom(value)
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        java.setObject(base64Decode, forKeyedSubscript: "base64Decode" as NSString)

        let hexEncode: @convention(block) (JSValue) -> String = { value in
            Data(JSEngine.stringFrom(value).utf8).map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(hexEncode, forKeyedSubscript: "hexEncode" as NSString)

        let hexDecode: @convention(block) (JSValue) -> String = { value in
            let text = JSEngine.stringFrom(value)
            var bytes: [UInt8] = []
            var index = text.startIndex
            while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
                if let byte = UInt8(text[index..<next], radix: 16) { bytes.append(byte) }
                index = next
            }
            return String(data: Data(bytes), encoding: .utf8) ?? ""
        }
        java.setObject(hexDecode, forKeyedSubscript: "hexDecode" as NSString)

        let digestHex: @convention(block) (JSValue, JSValue) -> String = { data, algorithm in
            Crypto.digestHex(JSEngine.stringFrom(data), algorithm: JSEngine.stringFrom(algorithm))
        }
        java.setObject(digestHex, forKeyedSubscript: "digestHex" as NSString)

        let hmacHex: @convention(block) (JSValue, JSValue, JSValue) -> String = { data, algorithm, keyValue in
            Crypto.hmacHex(JSEngine.stringFrom(data),
                           algorithm: JSEngine.stringFrom(algorithm),
                           key: JSEngine.stringFrom(keyValue))
        }
        java.setObject(hmacHex, forKeyedSubscript: "HMacHex" as NSString)

        // java.getString(rule[, content][, isUrl]) 与 java.getString(rule, unescape)。
        //
        // Legado 是**两个重载**（AnalyzeRule.kt:211 与 :217）：
        //   getString(ruleStr, mContent = null, isUrl = false, unescape = true)
        //   getString(ruleStr, unescape: Boolean)
        // Rhino 按实参类型选：第二个参数是布尔就走 unescape，否则当 content。
        // 全量语料实测 `java.getString(rule, false)` / `(rule, true)` 有 **2243 处**
        // （晋江[细分] 等源的正文规则大量这么写）。旧实现一律把第二参数当
        // content 传下去，内容变成一个布尔值，规则作用在非 HTML 值上恒取空 ——
        // 表现就是「这类源的正文一个字都出不来」。
        //
        // unescape：Legado 默认 true，对结果做 HTML 实体反转义
        // （StringEscapeUtils.unescapeHtml4）。src 里带 `&amp;` 的源文
        // 不反转义就会把实体原样显示给用户 —— 即用户看到的「乱码/字符」。
        let getString: @convention(block) (String, JSValue, JSValue) -> String = { [weak self] rule, second, third in
            guard let self else { return "" }
            var target: Any?
            var isURL = false
            var unescape = true
            if second.isBoolean {
                unescape = second.toBool()
            } else {
                if !second.isUndefined, !second.isNull { target = JSEngine.swiftValue(second) }
                if third.isBoolean { isURL = third.toBool() }
            }
            let value = self.host.resolveString?(rule, target, isURL) ?? ""
            return unescape ? HTMLParser.decodeEntities(value) : value
        }
        java.setObject(getString, forKeyedSubscript: "getString" as NSString)

        // 返回值必须是「像 java.util.List 的对象」而不是裸 JS 数组：
        // 书源写 bs.size() / bs.get(i)，裸数组只有 .length 没有 .size()，
        // 一调用就抛 TypeError（日志里的 "bs.size is not a function"）。
        let getStringList: @convention(block) (String, JSValue, JSValue) -> JSValue = { [weak self] rule, content, third in
            guard let self, let context = self.context else { return JSValue() }
            // 第二参数是布尔时说明调用方写了 unescape 形态的调用，
            // 这里没有对应重载，按「未指定内容」处理，不能把布尔当内容。
            var target: Any?
            if !content.isBoolean, !content.isUndefined, !content.isNull {
                target = JSEngine.swiftValue(content)
            }
            let isURL = third.isBoolean ? third.toBool() : false
            let values = self.host.resolveStringList?(rule, target, isURL) ?? []
            return JSEngine.makeListValue(values, in: context)
        }
        java.setObject(getStringList, forKeyedSubscript: "getStringList" as NSString)

        let setContent: @convention(block) (JSValue) -> Void = { [weak self] content in
            let value: Any? = (content.isUndefined || content.isNull) ? nil : JSEngine.swiftValue(content)
            self?.host.setContent?(value)
        }
        java.setObject(setContent, forKeyedSubscript: "setContent" as NSString)

        let getElement: @convention(block) (String) -> JSValue = { [weak self] rule in
            guard let self, let document = self.currentDocument() else { return JSValue() }
            guard let first = self.selectNodes(rule, in: document).first else {
                return JSValue()
            }
            return self.wrapElement(first)
        }
        java.setObject(getElement, forKeyedSubscript: "getElement" as NSString)

        // 同样返回 List 语义：书源写 java.getElements(..).size() / .get(i)。
        let getElements: @convention(block) (String) -> JSValue = { [weak self] rule in
            guard let self, let context = self.context, let document = self.currentDocument() else { return JSValue() }
            let nodes = self.selectNodes(rule, in: document)
            return JSEngine.makeElementListValue(nodes, engine: self, in: context)
        }
        java.setObject(getElements, forKeyedSubscript: "getElements" as NSString)

        let openUrl: @convention(block) (String) -> Void = { url in
            Log.debugLog("JS", "openUrl: " + url)
        }
        java.setObject(openUrl, forKeyedSubscript: "openUrl" as NSString)

        let timeFormat: @convention(block) (JSValue, JSValue) -> String = { time, format in
            let timestamp = RuleUtil.asDouble(JSEngine.swiftValue(time)) ?? Date().timeIntervalSince1970
            let seconds = timestamp > 1e12 ? timestamp / 1000 : timestamp
            var pattern = JSEngine.stringFrom(format)
            if pattern.isEmpty { pattern = "yyyy-MM-dd HH:mm" }
            pattern = pattern.replacingOccurrences(of: "YYYY", with: "yyyy")
            pattern = pattern.replacingOccurrences(of: "DD", with: "dd")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = pattern
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        java.setObject(timeFormat, forKeyedSubscript: "timeFormat" as NSString)

        let queryTTF: @convention(block) (JSValue) -> JSValue = { [weak self] _ in
            guard let context = self?.context else { return JSValue() }
            return JSValue(nullIn: context) ?? JSValue()
        }
        java.setObject(queryTTF, forKeyedSubscript: "queryTTF" as NSString)

        let replaceFont: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> String = { text, _, _, _ in
            JSEngine.stringFrom(text)
        }
        java.setObject(replaceFont, forKeyedSubscript: "replaceFont" as NSString)


        let encodeURIValue: @convention(block) (JSValue) -> String = { value in
            JSEngine.stringFrom(value).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        java.setObject(encodeURIValue, forKeyedSubscript: "encodeURI" as NSString)

        let encodeURIComponentValue: @convention(block) (JSValue) -> String = { value in
            JSEngine.stringFrom(value).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        }
        java.setObject(encodeURIComponentValue, forKeyedSubscript: "encodeURIComponent" as NSString)

        let t2s: @convention(block) (JSValue) -> String = { value in
            JSEngine.stringFrom(value)
        }
        java.setObject(t2s, forKeyedSubscript: "t2s" as NSString)
        java.setObject(t2s, forKeyedSubscript: "s2t" as NSString)

        let toast: @convention(block) (JSValue) -> Void = { [weak self] value in
            let text = JSEngine.stringFrom(value)
            Log.debugLog("JS toast", text)
            // 表单型发现源用 java.toast('请输入关键字') 提示用户；
            // 只写日志的话用户看不到任何反馈，会以为按钮坏了。
            self?.onToast?(text)
        }
        java.setObject(toast, forKeyedSubscript: "toast" as NSString)
        java.setObject(toast, forKeyedSubscript: "longToast" as NSString)

        let getUserAgent: @convention(block) () -> String = {
            JSEngine.userAgent
        }
        java.setObject(getUserAgent, forKeyedSubscript: "getUserAgent" as NSString)

        // getWebViewUA 必须与 getUserAgent **不同**：
        // 14 个源用二者的相等性判断自己是否跑在「源阅」上。
        let getWebViewUA: @convention(block) () -> String = {
            JSEngine.webViewUserAgent
        }
        java.setObject(getWebViewUA, forKeyedSubscript: "getWebViewUA" as NSString)

        // java.refreshExplore()：表单控件变化后要求发现页重新求值。
        // 实测 51 处（21 个源）。空实现时「切换频道 / 切换接口」点下去
        // 界面毫无变化，用户看到的就是「点了没用」。
        let refreshExplore: @convention(block) () -> Void = { [weak self] in
            self?.onRefreshExplore?()
        }
        java.setObject(refreshExplore, forKeyedSubscript: "refreshExplore" as NSString)

        // java.url 必须是**实时**的当前地址：脚本读它拼下一页 / 目录地址，
        // setup 时快照会让它永远停在书源入口域名。
        //
        // 闭包一律只弱持有 self，**不能**捕获 context：
        // getter 会挂在 java 上、java 又挂在 context 上，
        // 强引用 context 就构成 context → java → getter → context 的自环，
        // 每建一个 JSEngine 就漏掉一整个 JSVirtualMachine
        // （搜索几百个源就是几百个虚拟机，正是闪退的主因）。
        JSEngine.defineProperty("url", descriptor: JSEngine.propertyDescriptor(
            get: { [weak self] in
                guard let self, let context = self.context else { return JSValue() }
                return JSValue(object: self.host.baseUrl, in: context)
            },
            set: { [weak self] value in
                let text = JSEngine.stringFrom(value)
                if !text.isEmpty { self?.host.baseUrl = text }
            },
            in: context
        ), on: java, in: context)
        java.setObject(host.headers, forKeyedSubscript: "headerMap" as NSString)

        context.setObject(java, forKeyedSubscript: "java" as NSString)
    }

    private func setupSource(_ context: JSContext) {
        let source = JSEngine.newObject(in: context)

        // 对齐 Legado：getKey() 返回书源入口地址（bookSourceUrl）。
        //
        // 旧实现返回的是本 App 内部的 source.id（一个哈希），
        // 而书源拿它当域名用（`source.getKey()+"/api/search"`、
        // `cookie.removeCookie(source.getKey())`），
        // 于是请求地址全错、Cookie 也对不上号。
        let getKey: @convention(block) () -> String = { [weak self] in
            guard let self else { return "" }
            return self.host.sourceUrl.isEmpty ? self.host.sourceKey : self.host.sourceUrl
        }
        source.setObject(getKey, forKeyedSubscript: "getKey" as NSString)

        // 对齐 Legado：未保存过变量时返回**空串**，而不是 null。
        //
        // 书源普遍写 `JSON.parse(source.getVariable() || '{}')`，
        // 但也有 23 处（13 个源）直接写 `JSON.parse(source.getVariable())`。
        // JSON.parse(null) 不抛错、返回 null，于是紧接着的
        // `cfg.ch` / `vars.group` 就对 null 取属性 ——
        // TypeError 把整段脚本打断，用户看到的是「短剧 / 听书打不开」。
        // 返回空串时 JSON.parse('') 会抛错，正好落进书源自己的 try/catch 兜底。
        let getVariable: @convention(block) () -> String = { [weak self] in
            self?.sourceVariable ?? ""
        }
        source.setObject(getVariable, forKeyedSubscript: "getVariable" as NSString)

        let setVariable: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            let text = JSEngine.stringFrom(value)
            self.sourceVariable = text
            self.onVariableChanged?(text)
        }
        source.setObject(setVariable, forKeyedSubscript: "setVariable" as NSString)

        let getLoginHeader: @convention(block) () -> String? = { [weak self] in self?.loginHeader }
        source.setObject(getLoginHeader, forKeyedSubscript: "getLoginHeader" as NSString)

        // 同 getLoginInfoMap：书源按 java.util.Map 使用它（.get / .containsKey），
        // 桥成普通对象会让这些调用全部变成 "is not a function"。
        let getLoginHeaderMap: @convention(block) () -> JSValue = { [weak self] in
            guard let self, let context = self.context,
                  let header = self.loginHeader,
                  let dictionary = header.jsonObject as? [String: Any] else { return JSValue() }
            var result: [String: String] = [:]
            for (key, value) in dictionary { result[key] = RuleUtil.asString(value) ?? "" }
            let wrap = context.objectForKeyedSubscript("__dxWrapMap")
            guard let wrap, !wrap.isUndefined,
                  let raw = JSValue(object: result, in: context),
                  let mapped = wrap.call(withArguments: [raw]) else { return JSValue() }
            return mapped
        }
        source.setObject(getLoginHeaderMap, forKeyedSubscript: "getLoginHeaderMap" as NSString)

        let putLoginHeader: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.loginHeader = JSEngine.stringFrom(value)
        }
        source.setObject(putLoginHeader, forKeyedSubscript: "putLoginHeader" as NSString)

        let removeLoginHeader: @convention(block) () -> Void = { [weak self] in
            self?.loginHeader = nil
        }
        source.setObject(removeLoginHeader, forKeyedSubscript: "removeLoginHeader" as NSString)

        let getLoginInfo: @convention(block) () -> String? = { [weak self] in
            guard let info = self?.loginInfo, !info.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: info) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        source.setObject(getLoginInfo, forKeyedSubscript: "getLoginInfo" as NSString)

        // 返回 java.util.Map 而不是普通 JS 对象。
        //
        // 书源写的是 `info.get('账号')`（Map 语义），而 Swift 字典桥过去
        // 只是个普通对象，`info.get` 是 undefined ——
        // 实测日志里刷屏的 "TypeError: info.get is not a function"
        // 就是这里来的，登录脚本整段失效（微信读书 / 书旗等源依赖它）。
        // 交给 JS 侧的 __dxWrapMap 包一层：同时支持 info.get(k) 与 info[k]。
        let getLoginInfoMap: @convention(block) () -> JSValue = { [weak self] in
            guard let self, let context = self.context else { return JSValue() }
            let wrap = context.objectForKeyedSubscript("__dxWrapMap")
            guard let wrap, !wrap.isUndefined,
                  let raw = JSValue(object: self.loginInfo, in: context),
                  let mapped = wrap.call(withArguments: [raw]) else {
                return JSValue()
            }
            return mapped
        }
        source.setObject(getLoginInfoMap, forKeyedSubscript: "getLoginInfoMap" as NSString)

        let removeLoginInfo: @convention(block) () -> Void = { [weak self] in
            self?.loginInfo = [:]
        }
        source.setObject(removeLoginInfo, forKeyedSubscript: "removeLoginInfo" as NSString)

        let put: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.host.variables[name] = JSEngine.stringFrom(value)
        }
        source.setObject(put, forKeyedSubscript: "put" as NSString)

        let get: @convention(block) (String) -> String? = { [weak self] name in
            self?.host.variables[name]
        }
        source.setObject(get, forKeyedSubscript: "get" as NSString)

        // 下面这两个别名指向上面 **已按 Legado 语义实现**的版本。
        //
        // 这里曾经还接着注册 setVariable / getVariable / putVariable 的旧实现，
        // 用同一个 key 覆盖掉上面刚注册好的版本 —— Swift 的
        // setObject(_:forKeyedSubscript:) 是覆盖而非报错，于是
        //     source.getVariable()   → 桥成 undefined（旧实现返回 String?）
        //     source.setVariable(x)  → 不写回、不触发 onVariableChanged
        // 书源普遍写 `source.getVariable() || '{}'` / 先 set 再 get，
        // 拿不到值就整段走空，用户看到的是「短剧 / 听书打不开」。
        // 因此这里只保留别名映射，不要再注册任何 get/set 实现。
        source.setObject(getVariable, forKeyedSubscript: "getVariableMap" as NSString)
        source.setObject(setVariable, forKeyedSubscript: "putVariable" as NSString)
        source.setObject(getLoginHeader, forKeyedSubscript: "getLoginHeader" as NSString)
        source.setObject(getLoginInfoMap, forKeyedSubscript: "getLoginInfoMap" as NSString)
        let refreshJSLib: @convention(block) () -> Void = {}
        source.setObject(refreshJSLib, forKeyedSubscript: "refreshJSLib" as NSString)

        // putConcurrent：设置并发率，本实现按「不改行为」处理。
        // 书源会在批次开始/结束各调一次，缺了它就是 undefined is not a function。
        let putConcurrent: @convention(block) (JSValue) -> Void = { value in
            _ = JSEngine.stringFrom(value)
        }
        source.setObject(putConcurrent, forKeyedSubscript: "putConcurrent" as NSString)

        // 书源元信息：脚本会直接读这些字段拼地址 / 取 helper 源码。
        // 缺失时表现就是 "Can't find variable: org" 之外的
        // "undefined is not an object (evaluating 'source.bookSourceComment...')"。
        source.setObject(host.sourceUrl, forKeyedSubscript: "bookSourceUrl" as NSString)
        source.setObject(host.sourceUrl, forKeyedSubscript: "sourceUrl" as NSString)
        // source.key 在 Legado 里就是书源入口域名（getKey() 的字段形态）
        source.setObject(host.sourceUrl, forKeyedSubscript: "key" as NSString)
        source.setObject(host.sourceName, forKeyedSubscript: "bookSourceName" as NSString)
        source.setObject(host.sourceName, forKeyedSubscript: "name" as NSString)
        source.setObject(host.sourceComment, forKeyedSubscript: "bookSourceComment" as NSString)
        source.setObject(host.variableComment, forKeyedSubscript: "variableComment" as NSString)
        source.setObject(host.sourceHeader, forKeyedSubscript: "header" as NSString)
        source.setObject(host.loginUrl, forKeyedSubscript: "loginUrl" as NSString)
        source.setObject(host.concurrentRate, forKeyedSubscript: "concurrentRate" as NSString)

        // 书源声明里的其余字段整体透传。
        //
        // 上面逐个 setObject 的只是「调用点最多」的那批；语料里还有
        // bookSourceType / lastUpdateTime / exploreUrl / ruleExplore /
        // bookSourceGroup / loginUi / respondTime 等字段被脚本读取（源里写
        // `source.bookSourceType == '3'`、`timeFormat(source.lastUpdateTime)`
        // 这类直接比较）。缺一个就是 undefined 参与比较 —— 判断恒为 false，
        // 依赖它的分支整段走空，表现是「详情读不全 / 更新时间空白」。
        //
        // 必须在上面这些**已定值**的键之后写入，但要不覆盖它们：
        // 宿主算出来的值（例如 getKey 用的 sourceUrl）比原始声明更权威。
        for (key, value) in host.sourceMeta where !key.isEmpty {
            // 已定值的键跳过：宿主算出来的值比原始声明更权威
            // （例如 getKey 用的 sourceUrl 已经过 stripURLAnnotation）。
            if let existing = source.objectForKeyedSubscript(key), !existing.isUndefined { continue }
            source.setObject(value, forKeyedSubscript: key as NSString)
        }

        // source.putLoginInfo(json)：349 个源在登录成功后保存账号 / 密码。
        //
        // 书源写法是 `let a = source.getLoginInfoMap(); a["账号"]=…; source.putLoginInfo(JSON.stringify(a))`，
        // 传进来的是 JSON 文本。缺了它整段登录收尾直接 TypeError，
        // 用户看到的是「授权码填对了但一直提示未登录」。
        let putLoginInfo: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            var info = self.loginInfo
            if let dictionary = JSEngine.dictionaryFrom(value) {
                for (key, item) in dictionary { info[key] = RuleUtil.asString(item) ?? "" }
            } else if let dictionary = JSEngine.stringFrom(value).jsonObject as? [String: Any] {
                for (key, item) in dictionary { info[key] = RuleUtil.asString(item) ?? "" }
            }
            guard !info.isEmpty else { return }
            self.loginInfo = info
            self.onLoginInfoChanged?(info)
        }
        source.setObject(putLoginInfo, forKeyedSubscript: "putLoginInfo" as NSString)
        source.setObject(putLoginInfo, forKeyedSubscript: "putLoginInfoMap" as NSString)
        source.setObject(putLoginInfo, forKeyedSubscript: "setLoginInfoMap" as NSString)

        // source.variable：属性形态的源变量（28 个源直接赋值）。
        // 与 getVariable/setVariable 共用同一份存储，避免两套值打架。
        JSEngine.defineProperty("variable", descriptor: JSEngine.propertyDescriptor(
            get: { [weak self] in
                guard let self, let context = self.context else { return JSValue() }
                return JSValue(object: self.sourceVariable, in: context)
            },
            set: { [weak self] value in
                guard let self else { return }
                let text = JSEngine.stringFrom(value)
                self.sourceVariable = text
                self.onVariableChanged?(text)
            },
            in: context
        ), on: source, in: context)

        // source.getConcurrentRate() / getBookSourceUrl() / getSource() / getTag()
        let getConcurrentRate: @convention(block) () -> String = { [weak self] in
            self?.host.concurrentRate ?? ""
        }
        source.setObject(getConcurrentRate, forKeyedSubscript: "getConcurrentRate" as NSString)

        let getBookSourceUrl: @convention(block) () -> String = { [weak self] in
            self?.host.sourceUrl ?? ""
        }
        source.setObject(getBookSourceUrl, forKeyedSubscript: "getBookSourceUrl" as NSString)

        // source.getSource()：60 个源写 `source.getSource().bookSourceComment`
        // 取公共函数库。返回 source 自身即可满足这个用法。
        // 只弱持有 self，再由 self.context 取上下文：getSource 挂在 source 上、
        // source 又挂在 context 上，闭包强引用 context 会构成自环，
        // 每建一个 JSEngine 就漏掉一整个 JSVirtualMachine。
        let getSource: @convention(block) () -> JSValue = { [weak self] in
            guard let self, let context = self.context else { return JSValue() }
            return context.objectForKeyedSubscript("source") ?? JSValue()
        }
        source.setObject(getSource, forKeyedSubscript: "getSource" as NSString)

        let getTag: @convention(block) () -> String = { [weak self] in
            self?.host.sourceName ?? ""
        }
        source.setObject(getTag, forKeyedSubscript: "getTag" as NSString)

        // source.login()：脚本主动要求走登录流程（要求弹登录界面）。
        let login: @convention(block) () -> Void = { [weak self] in
            self?.onRequestLogin?()
        }
        source.setObject(login, forKeyedSubscript: "login" as NSString)

        // source.setLoginUi(js) / getLoginUi()：自定义登录表单。
        // 本实现不渲染自定义表单，但必须存在 —— 缺失即 undefined is not a function。
        let setLoginUi: @convention(block) (JSValue) -> Void = { value in
            _ = JSEngine.stringFrom(value)
        }
        source.setObject(setLoginUi, forKeyedSubscript: "setLoginUi" as NSString)
        let getLoginUi: @convention(block) () -> String = { "" }
        source.setObject(getLoginUi, forKeyedSubscript: "getLoginUi" as NSString)

        // source.bookUrlPattern：1 个源用它做地址匹配，给个空串避免 undefined。
        source.setObject("", forKeyedSubscript: "bookUrlPattern" as NSString)

        context.setObject(source, forKeyedSubscript: "source" as NSString)
    }

    private func setupBookChapter(_ context: JSContext) {
        let book = JSEngine.newObject(in: context)
        for key in ["name", "author", "bookUrl", "tocUrl", "origin", "originName", "coverUrl", "intro", "kind"] {
            book.setObject(host.bookInfo[key] ?? "", forKeyedSubscript: key as NSString)
        }
        for (key, value) in host.bookInfo {
            book.setObject(value, forKeyedSubscript: key as NSString)
        }

        // 阅读进度与目录规模：书源据此判断「这一章是不是当前在读章」、
        // 「还有没有下一章」。实测 durChapterIndex 880 个源、
        // totalChapterNum 619 个源、durChapterTitle 488 个源在读。
        book.setObject(host.bookUrl, forKeyedSubscript: "bookUrl" as NSString)
        book.setObject(host.bookType, forKeyedSubscript: "type" as NSString)
        book.setObject(host.durChapterIndex, forKeyedSubscript: "durChapterIndex" as NSString)
        book.setObject(host.durChapterTitle, forKeyedSubscript: "durChapterTitle" as NSString)
        book.setObject(host.totalChapterNum, forKeyedSubscript: "totalChapterNum" as NSString)
        book.setObject(host.totalChapterNum, forKeyedSubscript: "totalChapterCount" as NSString)
        book.setObject(host.canUpdate, forKeyedSubscript: "canUpdate" as NSString)
        book.setObject(host.customIntro, forKeyedSubscript: "customIntro" as NSString)
        book.setObject(host.latestChapterTitle, forKeyedSubscript: "latestChapterTitle" as NSString)
        book.setObject(host.latestChapterTitle, forKeyedSubscript: "lastChapterTitle" as NSString)
        book.setObject(host.bookStatus, forKeyedSubscript: "status" as NSString)
        book.setObject(host.reverseToc, forKeyedSubscript: "reverseToc" as NSString)
        book.setObject(host.useReplaceRule, forKeyedSubscript: "useReplaceRule" as NSString)
        // book.order：Legado 的书架序号。源写
        // `if (book && book.order != 0 && reading == '1')` 决定走不走书架同步，
        // 缺失时 undefined != 0 恒为 true —— 走进「不在书架」的分支。
        book.setObject(host.bookOrder, forKeyedSubscript: "order" as NSString)

        let getBookVariable: @convention(block) (String) -> String? = { [weak self] name in
            self?.host.variables[name]
        }
        book.setObject(getBookVariable, forKeyedSubscript: "getVariable" as NSString)

        let putBookVariable: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.host.variables[name] = JSEngine.stringFrom(value)
        }
        book.setObject(putBookVariable, forKeyedSubscript: "putVariable" as NSString)
        book.setObject(putBookVariable, forKeyedSubscript: "setVariable" as NSString)

        // book.setReverseToc(bool)：581 个源用它把目录反序。
        //
        // 这是**写**操作，必须回写宿主 —— 只在 JS 侧改标志位的话，
        // 宿主紧接着拿到的还是原目录，「目录正反序切换」点了没反应。
        let setReverseToc: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            let flag = value.isBoolean ? value.toBool() : JSEngine.stringFrom(value) == "true"
            self.host.reverseToc = flag
            self.bookMutation.reverseToc = flag
            self.host.onReverseTocChanged?(flag)
        }
        book.setObject(setReverseToc, forKeyedSubscript: "setReverseToc" as NSString)

        // book.setUseReplaceRule(bool)：158 个源用它开关「净化替换规则」。
        let setUseReplaceRule: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            self.host.useReplaceRule = value.isBoolean ? value.toBool() : true
        }
        book.setObject(setUseReplaceRule, forKeyedSubscript: "setUseReplaceRule" as NSString)

        // book.setType(int)：影视源用它把「小说」改成「影视」（bookSourceType 4）。
        let setType: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            let type = Int(value.toInt32())
            self.bookMutation.type = type
            self.host.onBookTypeChanged?(type)
        }
        book.setObject(setType, forKeyedSubscript: "setType" as NSString)

        // book.setBookUrl(url)：脚本改写书籍地址。
        let setBookUrl: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            let text = JSEngine.stringFrom(value)
            guard !text.isEmpty else { return }
            self.host.bookUrl = text
            self.bookMutation.bookUrl = text
        }
        book.setObject(setBookUrl, forKeyedSubscript: "setBookUrl" as NSString)

        // book.putCustomVariable(json)：60 个源用它保存「自定义购票/购买」状态。
        let putCustomVariable: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            let text = JSEngine.stringFrom(value)
            self.bookMutation.variable = text
            self.host.variables["customVariable"] = text
        }
        book.setObject(putCustomVariable, forKeyedSubscript: "putCustomVariable" as NSString)

        // book.upCustomIntro()：清掉用户自定义简介（14 个源在目录页调用）。
        let upCustomIntro: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            self.host.customIntro = ""
            self.bookMutation.customIntro = ""
        }
        book.setObject(upCustomIntro, forKeyedSubscript: "upCustomIntro" as NSString)

        // book.save() / book.delete()：Legado 的落库操作，本实现只保留可变状态。
        let saveBook: @convention(block) () -> Void = {}
        book.setObject(saveBook, forKeyedSubscript: "save" as NSString)
        book.setObject(saveBook, forKeyedSubscript: "delete" as NSString)

        // book.readConfig：148 个源写 `book.readConfig.useReplaceRule`，
        // 必须先判 null 才不会 TypeError。给一个带默认值的对象。
        let readConfig = JSEngine.newObject(in: context)
        readConfig.setObject(true, forKeyedSubscript: "useReplaceRule" as NSString)
        readConfig.setObject(false, forKeyedSubscript: "isNightTheme" as NSString)
        readConfig.setObject("", forKeyedSubscript: "textColor" as NSString)
        book.setObject(readConfig, forKeyedSubscript: "readConfig" as NSString)

        // book.customVariable：读回 book.putCustomVariable 写过的值。
        let customVariable: @convention(block) () -> String = { [weak self] in
            self?.host.variables["customVariable"] ?? ""
        }
        book.setObject(customVariable, forKeyedSubscript: "getCustomVariable" as NSString)

        // book.customVariable / book.variable：属性读取（315 个源读 book.variable）。
        // 走 getter 而不是静态快照，脚本先 putCustomVariable 再读也能拿到新值。
        JSEngine.defineProperty("variable", descriptor: JSEngine.propertyDescriptor(
            get: { [weak self] in
                guard let self, let context = self.context else { return JSValue() }
                guard let data = try? JSONSerialization.data(withJSONObject: self.host.variables.snapshot),
                      let text = String(data: data, encoding: .utf8) else { return JSValue(object: "", in: context) }
                return JSValue(object: text, in: context)
            },
            set: { [weak self] _ in },
            in: context
        ), on: book, in: context)

        JSEngine.defineProperty("customVariable", descriptor: JSEngine.propertyDescriptor(
            get: { [weak self] in
                guard let self, let context = self.context else { return JSValue() }
                return JSValue(object: self.host.variables["customVariable"] ?? "", in: context)
            },
            set: { [weak self] value in
                self?.host.variables["customVariable"] = JSEngine.stringFrom(value)
            },
            in: context
        ), on: book, in: context)

        // book.bookUrl / book.customIntro 可写：脚本会改它们。
        JSEngine.defineProperty("bookUrl", descriptor: JSEngine.propertyDescriptor(
            get: { [weak self] in
                guard let self, let context = self.context else { return JSValue() }
                return JSValue(object: self.host.bookUrl, in: context)
            },
            set: { [weak self] value in
                guard let self else { return }
                let text = JSEngine.stringFrom(value)
                guard !text.isEmpty else { return }
                self.host.bookUrl = text
                self.bookMutation.bookUrl = text
            },
            in: context
        ), on: book, in: context)

        JSEngine.defineProperty("customIntro", descriptor: JSEngine.propertyDescriptor(
            get: { [weak self] in
                guard let self, let context = self.context else { return JSValue() }
                return JSValue(object: self.host.customIntro, in: context)
            },
            set: { [weak self] value in
                guard let self else { return }
                let text = JSEngine.stringFrom(value)
                self.host.customIntro = text
                self.bookMutation.customIntro = text
            },
            in: context
        ), on: book, in: context)

        JSEngine.defineProperty("canUpdate", descriptor: JSEngine.propertyDescriptor(
            get: { [weak self] in
                guard let self, let context = self.context else { return JSValue() }
                return JSValue(object: self.host.canUpdate, in: context)
            },
            set: { [weak self] value in
                guard let self else { return }
                let flag = value.isBoolean ? value.toBool() : true
                self.host.canUpdate = flag
                self.bookMutation.canUpdate = flag
            },
            in: context
        ), on: book, in: context)

        context.setObject(book, forKeyedSubscript: "book" as NSString)

        let chapter = JSEngine.newObject(in: context)
        chapter.setObject("", forKeyedSubscript: "title" as NSString)
        chapter.setObject("", forKeyedSubscript: "url" as NSString)
        chapter.setObject("", forKeyedSubscript: "baseUrl" as NSString)
        chapter.setObject("", forKeyedSubscript: "bookUrl" as NSString)
        chapter.setObject(0, forKeyedSubscript: "index" as NSString)
        for (key, value) in host.chapterInfo {
            chapter.setObject(value, forKeyedSubscript: key as NSString)
        }


        let getChapterVariable: @convention(block) (String) -> String? = { [weak self] name in
            self?.host.variables[name]
        }
        chapter.setObject(getChapterVariable, forKeyedSubscript: "getVariable" as NSString)

        let putChapterVariable: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.host.variables[name] = JSEngine.stringFrom(value)
        }
        chapter.setObject(putChapterVariable, forKeyedSubscript: "putVariable" as NSString)
        chapter.setObject(putChapterVariable, forKeyedSubscript: "setVariable" as NSString)

        // chapter.putImgUrl(url)：把章节配图地址写回章节记录（11 个源）。
        // 传 null 表示清空。本实现记录到书籍级变量，宿主可读回。
        let putImgUrl: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            let text = value.isNull || value.isUndefined ? "" : JSEngine.stringFrom(value)
            self.host.variables["chapterImgUrl"] = text
        }
        chapter.setObject(putImgUrl, forKeyedSubscript: "putImgUrl" as NSString)

        // chapter.isVolume / chapter.title 之类属性已由 chapterInfo 注入；
        // 补齐常见但恒为默认值的字段，避免 undefined 参与运算。
        chapter.setObject(false, forKeyedSubscript: "isVolume" as NSString)
        chapter.setObject("", forKeyedSubscript: "volumeName" as NSString)
        chapter.setObject("", forKeyedSubscript: "tag" as NSString)
        chapter.setObject("", forKeyedSubscript: "updateTime" as NSString)
        chapter.setObject(false, forKeyedSubscript: "isVip" as NSString)

        context.setObject(chapter, forKeyedSubscript: "chapter" as NSString)
    }

    private func setupCookie(_ context: JSContext) {
        let cookie = JSEngine.newObject(in: context)

        let getCookie: @convention(block) (String) -> String = { [weak self] urlString in
            guard let self, let url = URL(string: urlString) else { return "" }
            return CookieJar.shared.cookieHeader(for: self.host.sourceKey, url: url) ?? ""
        }
        cookie.setObject(getCookie, forKeyedSubscript: "getCookie" as NSString)

        let getKey: @convention(block) (String, String) -> String = { [weak self] urlString, name in
            guard let self, let url = URL(string: urlString),
                  let header = CookieJar.shared.cookieHeader(for: self.host.sourceKey, url: url) else { return "" }
            for pair in header.components(separatedBy: ";") {
                let tokens = pair.components(separatedBy: "=")
                if tokens.count >= 2, tokens[0].trimmingCharacters(in: .whitespaces) == name {
                    return tokens.dropFirst().joined(separator: "=")
                }
            }
            return ""
        }
        cookie.setObject(getKey, forKeyedSubscript: "getKey" as NSString)

        let setCookie: @convention(block) (String, String) -> Void = { [weak self] urlString, value in
            guard let self, let url = URL(string: urlString) else { return }
            CookieJar.shared.setCookie(value, for: self.host.sourceKey, url: url)
        }
        cookie.setObject(setCookie, forKeyedSubscript: "setCookie" as NSString)

        // cookie.setWebCookie(url, cookie)：WebView 里的 cookie 回写。
        // 41 个源用它把「浏览器里拿到的登录态」存进 CookieJar。
        let setWebCookie: @convention(block) (String, String) -> Void = { [weak self] urlString, value in
            guard let self else { return }
            let target = urlString.isEmpty ? self.host.baseUrl : urlString
            guard let url = URL(string: target) else { return }
            CookieJar.shared.setCookie(value, for: self.host.sourceKey, url: url)
        }
        cookie.setObject(setWebCookie, forKeyedSubscript: "setWebCookie" as NSString)

        // cookie.mapToCookie(rawHeader)：把响应里的 set-cookie 原始串
        // 转成 CookieJar 能吃的形态（16 个源用它做登录回写）。
        let mapToCookie: @convention(block) (JSValue) -> String = { [weak self] value in
            guard let self else { return "" }
            let text = JSEngine.stringFrom(value)
            guard !text.isEmpty, let url = URL(string: self.host.baseUrl) else { return "" }
            let pairs = CookieJar.splitPairs(text)
            guard !pairs.isEmpty else { return "" }
            CookieJar.shared.setCookiePairs(text, for: self.host.sourceKey, url: url)
            return pairs.joined(separator: "; ")
        }
        cookie.setObject(mapToCookie, forKeyedSubscript: "mapToCookie" as NSString)

        let replaceCookie: @convention(block) (String, String) -> Void = { [weak self] urlString, value in
            guard let self, let url = URL(string: urlString) else { return }
            CookieJar.shared.clear(sourceKey: self.host.sourceKey)
            CookieJar.shared.setCookie(value, for: self.host.sourceKey, url: url)
        }
        cookie.setObject(replaceCookie, forKeyedSubscript: "replaceCookie" as NSString)

        let removeCookie: @convention(block) (String) -> Void = { [weak self] _ in
            guard let self else { return }
            CookieJar.shared.clear(sourceKey: self.host.sourceKey)
        }
        cookie.setObject(removeCookie, forKeyedSubscript: "removeCookie" as NSString)

        context.setObject(cookie, forKeyedSubscript: "cookie" as NSString)
    }

    private func setupCache(_ context: JSContext) {
        let cacheObject = JSEngine.newObject(in: context)

        let get: @convention(block) (String) -> String? = { [weak self] name in self?.cache[name] }
        cacheObject.setObject(get, forKeyedSubscript: "get" as NSString)

        let put: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] name, value, _ in
            self?.cache[name] = JSEngine.stringFrom(value)
        }
        cacheObject.setObject(put, forKeyedSubscript: "put" as NSString)

        let delete: @convention(block) (String) -> Void = { [weak self] name in
            self?.cache.removeValue(forKey: name)
        }
        cacheObject.setObject(delete, forKeyedSubscript: "delete" as NSString)

        let getFile: @convention(block) (String) -> String? = { [weak self] name in self?.cache[name] }
        cacheObject.setObject(getFile, forKeyedSubscript: "getFile" as NSString)

        let putFile: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] name, value, _ in
            self?.cache[name] = JSEngine.stringFrom(value)
        }
        cacheObject.setObject(putFile, forKeyedSubscript: "putFile" as NSString)

        let putMemory: @convention(block) (String, JSValue) -> Void = { [weak self] name, value in
            self?.cache[name] = JSEngine.stringFrom(value)
        }
        cacheObject.setObject(putMemory, forKeyedSubscript: "putMemory" as NSString)

        let getFromMemory: @convention(block) (String) -> String? = { [weak self] name in self?.cache[name] }
        cacheObject.setObject(getFromMemory, forKeyedSubscript: "getFromMemory" as NSString)

        let deleteMemory: @convention(block) (String) -> Void = { [weak self] name in
            self?.cache.removeValue(forKey: name)
        }
        cacheObject.setObject(deleteMemory, forKeyedSubscript: "deleteMemory" as NSString)

        context.setObject(cacheObject, forKeyedSubscript: "cache" as NSString)
    }

    // MARK: 网络响应

    /// 被 JSEngineRuntime.swift 的 ajaxAll / getStrResponse / head 复用，
    /// 因此不能是 private（Swift 的 private 是文件级作用域）。
    func connect(url urlString: String, header: JSValue?, method: String?, body: String?) -> JSValue {
        guard let context else { return JSEngine.undefinedValue }
        guard !urlString.isEmpty else { return JSEngine.undefinedValue }

        var options = HTTPRequestOptions()
        if let method { options.method = method }
        options.body = body

        var headers = host.headers
        if let header, !header.isUndefined, !header.isNull {
            if let dictionary = JSEngine.dictionaryFrom(header) {
                for (key, value) in dictionary { headers[key] = RuleUtil.asString(value) ?? "" }
            } else {
                let text = JSEngine.stringFrom(header)
                if let dictionary = text.jsonObject as? [String: Any] {
                    for (key, value) in dictionary { headers[key] = RuleUtil.asString(value) ?? "" }
                }
            }
        }

        let (finalURL, parsedOptions) = HTTPClient.parseURLRule(urlString)
        if parsedOptions.body != nil || parsedOptions.method != "GET" {
            options.method = parsedOptions.method
            options.body = parsedOptions.body
        }
        for (key, value) in parsedOptions.headers { headers[key] = value }
        let resolvedURL = RuleUtil.absoluteURL(finalURL, base: host.baseUrl)
        do {
            let response = try HTTPClient.shared.requestSync(
                urlString: resolvedURL,
                options: options,
                sourceKey: host.sourceKey,
                defaultHeaders: headers
            )
            return makeResponseObject(response, context: context)
        } catch {
            Log.debugLog("JS", "请求失败: " + error.localizedDescription + " url=" + resolvedURL)
            let object = JSEngine.newObject(in: context)
            object.setObject("", forKeyedSubscript: "body" as NSString)
            object.setObject("", forKeyedSubscript: "__text" as NSString)
            object.setObject(0, forKeyedSubscript: "code" as NSString)
            return object
        }
    }

    func makeResponseObject(_ response: HTTPResponse, context: JSContext) -> JSValue {
        let object = JSEngine.newObject(in: context)
        let text = response.text
        let headerMap = response.headers
        let statusCode = response.statusCode
        let finalURL = response.finalURL?.absoluteString ?? ""

        let body: @convention(block) () -> String = { text }
        object.setObject(body, forKeyedSubscript: "body" as NSString)
        object.setObject(text, forKeyedSubscript: "__text" as NSString)
        object.setObject(text, forKeyedSubscript: "text" as NSString)

        let string: @convention(block) () -> String = { text }
        object.setObject(string, forKeyedSubscript: "string" as NSString)

        let header: @convention(block) (String) -> String = { name in
            let lowered = name.lowercased()
            for (key, value) in headerMap where key.lowercased() == lowered { return value }
            return ""
        }
        object.setObject(header, forKeyedSubscript: "header" as NSString)

        let code: @convention(block) () -> Int = { statusCode }
        object.setObject(code, forKeyedSubscript: "code" as NSString)
        object.setObject(statusCode, forKeyedSubscript: "statusCode" as NSString)

        let allHeaders: @convention(block) () -> [String: String] = { headerMap }
        object.setObject(allHeaders, forKeyedSubscript: "headers" as NSString)

        let raw: @convention(block) () -> JSValue = { [weak context] in
            guard let context else { return JSEngine.undefinedValue }
            let rawObject = JSEngine.newObject(in: context)
            let request: @convention(block) () -> JSValue = { [weak context] in
                guard let context else { return JSEngine.undefinedValue }
                let requestObject = JSEngine.newObject(in: context)
                let urlFunction: @convention(block) () -> String = { finalURL }
                requestObject.setObject(urlFunction, forKeyedSubscript: "url" as NSString)
                let headerFunction: @convention(block) (String) -> String = { name in
                    let lowered = name.lowercased()
                    for (key, value) in headerMap where key.lowercased() == lowered { return value }
                    return ""
                }
                requestObject.setObject(headerFunction, forKeyedSubscript: "header" as NSString)
                return requestObject
            }
            rawObject.setObject(request, forKeyedSubscript: "request" as NSString)
            return rawObject
        }
        object.setObject(raw, forKeyedSubscript: "raw" as NSString)

        return object
    }

    // MARK: 元素包装

    /// jsoup 桩（JSEngineRuntime.swift）也要用，不能是 private。
    func wrapElement(_ node: HTMLNode) -> JSValue {
        guard let context else { return JSEngine.undefinedValue }
        return wrapElement(node, in: context)
    }

    func wrapElement(_ node: HTMLNode, in context: JSContext) -> JSValue {
        let object = JSEngine.newObject(in: context)

        let text: @convention(block) () -> String = { node.normalizedText }
        object.setObject(text, forKeyedSubscript: "text" as NSString)

        let ownText: @convention(block) () -> String = { node.ownText }
        object.setObject(ownText, forKeyedSubscript: "ownText" as NSString)

        let html: @convention(block) () -> String = { node.innerHTML }
        object.setObject(html, forKeyedSubscript: "html" as NSString)

        let outerHtml: @convention(block) () -> String = { node.outerHTML }
        object.setObject(outerHtml, forKeyedSubscript: "outerHtml" as NSString)

        let attr: @convention(block) (String) -> String = { name in node.attribute(name) ?? "" }
        object.setObject(attr, forKeyedSubscript: "attr" as NSString)

        let hasClass: @convention(block) (String) -> Bool = { node.hasClass($0) }
        object.setObject(hasClass, forKeyedSubscript: "hasClass" as NSString)

        let tagName: @convention(block) () -> String = { node.name }
        object.setObject(tagName, forKeyedSubscript: "tagName" as NSString)

        // jsoup 元素还提供 val()：取 value 属性。书源里偶有使用。
        let val: @convention(block) () -> String = { node.attribute("value") ?? "" }
        object.setObject(val, forKeyedSubscript: "val" as NSString)

        let select: @convention(block) (String) -> JSValue = { [weak self] rule in
            guard let self, let context = self.context else { return JSValue() }
            let matched = CSSSelector.select(rule, in: node)
            return JSEngine.makeElementListValue(matched, engine: self, in: context)
        }
        object.setObject(select, forKeyedSubscript: "select" as NSString)

        let selectFirst: @convention(block) (String) -> JSValue = { [weak self] rule in
            guard let self, let first = CSSSelector.select(rule, in: node).first else {
                return JSValue()
            }
            return self.wrapElement(first)
        }
        object.setObject(selectFirst, forKeyedSubscript: "selectFirst" as NSString)

        return object
    }

    /// 统一的选择入口：XPath / 传统选择器 / CSS。
    ///
    /// 书源脚本里 java.getElements('class.comic-contain@amp-img') 这类写法很常见，
    /// 传统选择器必须与规则引擎走同一套求值。
    private func selectNodes(_ rule: String, in document: HTMLNode) -> [HTMLNode] {
        let (kind, body) = RuleSyntax.detectKind(rule)
        if kind == .xpath { return XPathEngine.nodes(body, document: document) }
        if LegacySelector.isLegacy(body) { return LegacySelector.select(body, in: document) }
        return CSSSelector.select(body, in: document)
    }

    private func currentDocument() -> HTMLNode? {
        if let document = host.document { return document }
        if !src.isEmpty { return HTMLParser.parse(src) }
        return nil
    }

    // MARK: 值转换

    /// 新建一个空 JS 对象。
    ///
    /// 不要用 `JSValue(newObjectIn:) ?? ...`：该初始化器返回的是可选值，
    /// 一旦用 `??` 兜底，整个表达式的类型就退化成 `JSValue?`，
    /// 后续所有 `setObject(_:forKeyedSubscript:)` 都会编译失败
    /// （CI 上一次 86 个 error 全部出自这里）。
    /// 统一收口成一个返回非可选值的方法，既修类型又保留兜底。
    static func newObject(in context: JSContext) -> JSValue {
        if let object = JSValue(newObjectIn: context) { return object }
        return JSValue()
    }

    /// 构造一个「带 getter / setter 的属性定义」。
    ///
    /// 书源里既有 `source.getVariable()`，也有 `source.variable = …` 的
    /// 属性赋值写法（实测 28 个源）。属性赋值若不经过 setter，
    /// 宿主就收不到 onVariableChanged，用户改的源变量下次刷新又回到默认值。
    /// 这里返回 Object.defineProperty 的 descriptor，由 JS 侧应用。
    static func propertyDescriptor(
        get getter: @escaping () -> JSValue,
        set setter: @escaping (JSValue) -> Void,
        in context: JSContext
    ) -> JSValue {
        let descriptor = newObject(in: context)
        let getterBlock: @convention(block) () -> JSValue = getter
        let setterBlock: @convention(block) (JSValue) -> Void = setter
        descriptor.setObject(getterBlock, forKeyedSubscript: "get" as NSString)
        descriptor.setObject(setterBlock, forKeyedSubscript: "set" as NSString)
        descriptor.setObject(true, forKeyedSubscript: "enumerable" as NSString)
        descriptor.setObject(true, forKeyedSubscript: "configurable" as NSString)
        return descriptor
    }

    /// 把 propertyDescriptor 定义到目标对象上。
    static func defineProperty(_ name: String, descriptor: JSValue, on object: JSValue, in context: JSContext) {
        guard let define = context.objectForKeyedSubscript("Object")?
            .objectForKeyedSubscript("defineProperty"), !define.isUndefined else {
            // 没有 Object.defineProperty（不应发生）：退化成直接赋值，至少不抛错
            object.setObject(descriptor.objectForKeyedSubscript("get")?.call(withArguments: []) ?? JSValue(),
                             forKeyedSubscript: name as NSString)
            return
        }
        _ = define.call(withArguments: [object, name, descriptor])
    }

    /// 引擎已释放时的占位值。
    ///
    /// 旧实现是 JSValue(undefinedIn: nil) —— 用 nil 上下文构造 JSValue 属于
    /// 未定义行为，把这个对象交回 JavaScriptCore 会在 JSC::evaluate 内部
    /// 直接命中 breakpoint trap（SIGTRAP）。
    /// JSValue() 的空值语义就等价于 undefined，且完全合法。
    static var undefinedValue: JSValue {
        JSValue()
    }



    static func stringFrom(_ value: JSValue?) -> String {
        guard let value, !value.isUndefined, !value.isNull else { return "" }
        if value.isString { return value.toString() ?? "" }
        if value.isBoolean { return value.toBool() ? "true" : "false" }
        if value.isNumber {
            let double = value.toDouble()
            if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
            return String(double)
        }
        if value.isArray || value.isObject {
            if let context = value.context,
               let stringify = context.objectForKeyedSubscript("JSON")?.objectForKeyedSubscript("stringify"),
               let json = stringify.call(withArguments: [value])?.toString() {
                return json
            }
        }
        return value.toString() ?? ""
    }

    /// 构造一个带 java.util.List 语义的 JS 值。
    ///
    /// 书源对集合的用法是 Java 的，不是 JavaScript 的：
    /// 它们调 .size() / .get(i) / .isEmpty()，而不是读 .length。
    /// 直接桥成 JS 数组会让这些调用全部变成 TypeError，
    /// 而这些 TypeError 又发生在我们 @convention(block) 的回调返回路径上，
    /// 很容易在 JavaScriptCore 内部升级成硬崩溃。
    ///
    /// 这里返回一个同时支持两套 API 的对象：数值索引、.length 让 JS 原生写法可用，
    /// .size() / .get() / .iterator() 让 Java 写法可用。
    static func makeListValue(_ items: [String], in context: JSContext) -> JSValue {
        let array = items.map { $0 as NSString }
        guard let value = JSValue(object: array, in: context) else { return JSValue() }
        let list = context.objectForKeyedSubscript("__dxWrapList")
        if let list, !list.isUndefined, let wrapped = list.call(withArguments: [value]) {
            return wrapped
        }
        return value
    }

    /// 元素列表版本：把 HTMLNode 包装对象组成 List。
    ///
    /// 注意这里不能在 JS 侧组装：wrapElement 的结果是 JSValue，
    /// 需要由它自己的上下文创建数组，跨上下文构造属未定义行为。
    static func makeElementListValue(_ nodes: [HTMLNode], engine: JSEngine, in context: JSContext) -> JSValue {
        let wrapped = nodes.map { engine.wrapElement($0, in: context) }
        guard let array = JSValue(newArrayIn: context) else { return JSValue() }
        for (index, element) in wrapped.enumerated() {
            array.setObject(element, atIndexedSubscript: index)
        }
        let list = context.objectForKeyedSubscript("__dxWrapList")
        if let list, !list.isUndefined, let result = list.call(withArguments: [array]) {
            return result
        }
        return array
    }

    static func dictionaryFrom(_ value: JSValue) -> [String: Any]? {
        if let object = value.toObject(), JSONSerialization.isValidJSONObject(object) { return object as? [String: Any] }
        let text = stringFrom(value)
        return text.jsonObject as? [String: Any]
    }

    /// 单个数组桥接的元素上限。
    ///
    /// 这条路径是「JS 返回值 → Swift 值」的唯一出口。书源里的递归通配规则
    /// 作用在 MB 级 JSON 上时，JS 侧会给出十万级元素的数组；
    /// 逐元素桥接会一次性申请巨量内存（每个元素都要建 JSValue 再转 Swift），
    /// 内存不够时进程被系统清掉。真实规则只需要前若干条，这里截断即可。
    private static let maxBridgeCount = 5_000

    /// 桥接深度上限：自引用对象（JS 里很常见）会让递归无上限展开直到栈溢出。
    private static let maxBridgeDepth = 32

    static func swiftValue(_ value: JSValue?) -> Any? {
        swiftValue(value, depth: 0)
    }

    private static func swiftValue(_ value: JSValue?, depth: Int) -> Any? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        // 自引用结构：到深度上限直接放弃展开，返回字符串表示，避免无限递归。
        guard depth < maxBridgeDepth else { return stringFrom(value) }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber {
            let double = value.toDouble()
            if double == double.rounded(), abs(double) < 1e15 { return Int64(double) }
            return double
        }
        if value.isArray {
            let array = value.toArray() ?? []
            let limited = array.count > maxBridgeCount ? Array(array.prefix(maxBridgeCount)) : array
            // value.context 可能为 nil（对象已随引擎释放）。
            // 原写法把 nil 直接传给 JSValue(object:in:)，属于未定义行为；
            // 这里没有上下文时退回字符串化，绝不构造非法 JSValue。
            guard let context = value.context else {
                // 没有上下文就无法构造 JSValue，退回原值的字符串表示，
                // 既保住了内容，也不会触发未定义行为。
                return limited.map { String(describing: $0) }
            }
            return limited.map { element -> Any? in
                // 只桥接真正的 Objective-C 对象：toArray() 正常都给 NSObject，
                // 但一旦混进纯 Swift 值，JSValue(object:) 会走未定义行为。
                guard let object = element as? NSObject else {
                    return RuleUtil.asString(element) ?? ""
                }
                return swiftValue(JSValue(object: object, in: context), depth: depth + 1)
            }
        }
        if value.isObject {
            if let object = value.toObject(), JSONSerialization.isValidJSONObject(object) { return object }
            let text = stringFrom(value)
            return text.jsonObject ?? text
        }
        return value.toString()
    }

    // MARK: - 注入前净化

    /// 把一个 Swift 值净化为「JavaScriptCore 一定认识」的形态。
    ///
    /// `JSContext.setObject(_:forKeyedSubscript:)` 只接受 Objective-C 可桥接的值
    /// （NSString / NSNumber / NSArray / NSDictionary / NSNull / block / JSValue）。
    /// 一旦传进去一个纯 Swift 类型（本项目的 `HTMLNode` 就是 pure Swift `final class`，
    /// 不继承 NSObject、没有 ObjC 元数据），JavaScriptCore 的桥接层会去反射它的
    /// 内存布局：先退化成 CoreFoundation 的对象描述，再在 Swift 运行时里读
    /// `UnsafeBufferPointer.baseAddress` —— 这一步直接触发 Swift 运行时陷阱
    /// （SIGABRT），崩在 JavaScriptCore 自己的线程里，现场只剩
    /// `JavaScriptCore → CoreFoundation → libswiftCore → abort` 一串看不懂的帧。
    ///
    /// 这不是理论问题：书源规则链里 `<js>…</js>` 的前一步结果经常就是 HTMLNode。
    /// 搜索时 `listItems` 把列表条目（HTMLNode）作为上下文交给规则，
    /// 于是任何 `@js:` 或 `{{插值}}` 都会把 HTMLNode 写进 `js.result`，
    /// 再由这里注入 JS 全局 —— 多源搜索会成百上千次走到这条路径，
    /// 这正是「搜到某个数量就闪退」而崩溃栈全是 JavaScriptCore 帧的根因。
    ///
    /// 这里在最外层出口统一净化一次：认识的类型原样保留，
    /// 不认识的降级成字符串（复用 RuleUtil 已有的文本化逻辑），
    /// 并且递归清洗容器，保证没有任何非桥接值漏进 JavaScriptCore。
    static func jsSafeValue(_ value: Any?) -> Any {
        jsSafeValue(value, depth: 0)
    }

    private static func jsSafeValue(_ value: Any?, depth: Int) -> Any {
        guard let value else { return NSNull() }
        // 深度上限：HTMLNode 互相引用，容器也可能自引用，无上限展开会栈溢出。
        if depth >= maxBridgeDepth { return RuleUtil.asString(value) ?? "" }

        if let text = value as? String { return text }
        // 纯 Swift 类型在这里被拦下，绝不进入 JavaScriptCore 的桥接层。
        if let node = value as? HTMLNode { return XPathEngine.stringValue(of: node) }
        // 数字要区分「布尔」与「数值」：Swift 里 NSNumber(1) as? Bool 也会成功，
        // 直接用 `as? Bool` 会把 JSON 里的数字 1 变成 true，脚本语义就错了。
        // 只有 CFBoolean 类型的 NSNumber 才是真正的布尔。
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number
        }
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return number }
        if let number = value as? Double { return number }
        if let number = value as? Float { return number }

        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, item) in dictionary {
                if output.count >= maxBridgeCount { break }
                output[key] = jsSafeValue(item, depth: depth + 1)
            }
            return output
        }
        if let array = value as? [Any] {
            let limited = array.count > maxBridgeCount ? Array(array.prefix(maxBridgeCount)) : array
            return limited.map { jsSafeValue($0, depth: depth + 1) }
        }

        // 兜底：文本化。宁可让脚本少看到一个字段，也不能让进程崩在桥接层。
        return RuleUtil.asString(value) ?? ""
    }
}

// MARK: - 摘要 / HMAC

enum Crypto {
    static func md5(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func digestHex(_ text: String, algorithm: String) -> String {
        let data = Data(text.utf8)
        let bytes: [UInt8]
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5": bytes = Array(Insecure.MD5.hash(data: data))
        case "SHA1": bytes = Array(Insecure.SHA1.hash(data: data))
        case "SHA256": bytes = Array(SHA256.hash(data: data))
        case "SHA384": bytes = Array(SHA384.hash(data: data))
        case "SHA512": bytes = Array(SHA512.hash(data: data))
        default: bytes = Array(SHA256.hash(data: data))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacHex(_ text: String, algorithm: String, key: String) -> String {
        let keyData = SymmetricKey(data: Data(key.utf8))
        let data = Data(text.utf8)
        let code: [UInt8]
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5": code = Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: keyData))
        case "SHA1": code = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: keyData))
        case "SHA256": code = Array(HMAC<SHA256>.authenticationCode(for: data, using: keyData))
        case "SHA384": code = Array(HMAC<SHA384>.authenticationCode(for: data, using: keyData))
        case "SHA512": code = Array(HMAC<SHA512>.authenticationCode(for: data, using: keyData))
        default: code = Array(HMAC<SHA256>.authenticationCode(for: data, using: keyData))
        }
        return code.map { String(format: "%02x", $0) }.joined()
    }
}
