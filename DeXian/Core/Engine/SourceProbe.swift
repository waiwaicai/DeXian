import Foundation

/// 书源有效性探测。
///
/// 书源仓库动辄上千个源，其中相当一部分站点早已下线、改版或加了登录墙。
/// 用户手上真正能用的是少数，但没有任何办法分辨 —— 只能一个个点开试。
/// 这里用「拿一个关键词去搜，能不能搜出书」作为判据：
///
/// - 搜到书 -> 有效（顺带把命中数量显示出来，方便判断源的强度）
/// - 请求失败 / 超时 / 解析不出结果 -> 无效，并带上原因
///
/// 判据刻意选「搜索」而不是「打开首页」：书源能否打开首页与实际能不能
/// 用没有必然关系，很多源首页是 JS 渲染的静态页，但搜索接口是好的。
enum SourceProbe {

    /// 单个源探测的结果
    enum State: Equatable {
        case valid(count: Int)
        case invalid(reason: String)
        /// 用户自己关掉的源：不探测，也绝不能被自动清理
        case skipped(reason: String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }

        var displayText: String {
            switch self {
            case .valid(let count): return "可用 · 搜到 " + String(count) + " 本"
            case .invalid(let reason): return reason
            case .skipped(let reason): return reason
            }
        }

        /// 无效原因是否属于「网络不通 / 站点没了」这类可以安全清理的情况。
        ///
        /// 这里用**白名单**而不是黑名单，因为反过来的代价不对称：
        /// 漏清一个死源只是少赚，误清一个能用的源是用户实打实的损失。
        /// 所以只承认「确定是源自己的问题」的那几类原因：
        ///
        /// - 域名解析失败 / 无法连接服务器 / 链接格式不支持：站点没了或规则写错了
        /// - 该源不支持搜索：无法被搜索到，留在启用列表只会拖慢每一轮
        /// - 搜索无结果：能连通但解析不出书，规则已失效
        ///
        /// 以下一律**不清理**：
        /// - 当前无网络 / 网络连接中断：是用户这边的网络问题，
        ///   若按「失败即清理」处理，用户在电梯里点一下就会清空整个书源库
        /// - 请求已取消 / 已取消：用户自己按了停止
        /// - 登录相关：源是好的，只是没配置账号
        /// - 用户主动禁用的源：那是他的选择，不是源的毛病
        var isRemovable: Bool {
            switch self {
            case .valid, .skipped: return false
            case .invalid(let reason):
                return Self.definitelyDeadReasons.contains { reason.contains($0) }
            }
        }

        /// 判定为「源本身已失效」的原因白名单
        private static let definitelyDeadReasons = [
            "域名解析失败",
            "无法连接服务器",
            "链接格式不支持",
            "不支持搜索",
            "搜索无结果",
            "服务器响应异常",
            "内容为空",
            "正文为空",
            "目录为空",
            "正文过短"
        ]
    }

    /// 探测一个源。不会抛错，一切失败都落到 `.invalid`。
    static func probe(_ source: BookSource, keyword: String) async -> State {
        guard source.enabled else { return .skipped(reason: "已禁用") }
        let url = source.resolvedSearchRequest.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return .invalid(reason: "不支持搜索") }

        do {
            let books = try await SourceEngine(source: source).search(keyword: keyword, page: 1)
            if books.isEmpty {
                // 能连通但搜不到：站点改版 / 搜索规则失效，对用户等同无效
                return .invalid(reason: "搜索无结果")
            }
            return .valid(count: books.count)
        } catch {
            return .invalid(reason: SourceError.describe(error))
        }
    }


    /// 基于真实正文的兼容性诊断；搜索成功但正文为空/过短的源也要被识别。
    static func probeContent(
        _ source: BookSource,
        keyword: String,
        engine: SourceEngine? = nil
    ) async -> State {
        let resolvedEngine = engine ?? SourceEngine(source: source)
        do {
            let books = try await resolvedEngine.search(keyword: keyword, page: 1)
            guard let first = books.first else { return .invalid(reason: "搜索无结果") }
            let chapters = try await resolvedEngine.toc(
                tocUrl: first.bookUrl,
                bookInfo: ["name": first.name, "author": first.author, "bookUrl": first.bookUrl]
            )
            guard let chapter = chapters.first else {
                return .invalid(reason: first.type == .image || first.type == .video || first.type == .audio ? "正文为空" : "目录为空")
            }
            let content = try await resolvedEngine.content(
                chapterUrl: chapter.url,
                bookInfo: ["name": first.name, "author": first.author, "bookUrl": first.bookUrl],
                chapterInfo: ["title": chapter.title, "url": chapter.url, "index": String(chapter.index), "bookUrl": first.bookUrl],
                chapterTitle: chapter.title
            )
            if first.type == .image {
                return content.images.isEmpty ? .invalid(reason: "正文为空") : .valid(count: content.images.count)
            }
            if first.type == .video {
                return content.text.isEmpty ? .invalid(reason: "正文为空") : .valid(count: 1)
            }
            if first.type == .audio {
                return content.text.isEmpty ? .invalid(reason: "正文为空") : .valid(count: 1)
            }
            let count = content.text.count
            guard count >= 30 else { return .contentTooShort(count) }
            return .valid(count: 1)
        } catch {
            return .error(SourceError.describe(error))
        }
    }
}
