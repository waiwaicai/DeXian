import Foundation

/// 订阅源分类（订阅源界面里的"栏目"）
struct RssCategory: Hashable, Identifiable {
    var id: String { title + "|" + url }
    var title: String
    var url: String
}

/// 订阅源（RSS）：字段命名以 Legado(阅读 3.x) 的 RssSource 为准。
///
/// 与书源的区别：订阅源没有目录/章节概念，
/// 规则是一页文章列表（ruleArticles + ruleTitle/ruleLink/rulePubDate/...）。
/// 同时兼容两类常见形态：
/// - 带规则源：ruleArticles 等字段齐全（例：中文寻星、秀人集）
/// - 无规则源：只有 sourceUrl，靠页面上的链接直接罗列（例：源仓库官方纯净）
struct RssSource: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var url: String
    var icon: String
    var group: String
    var comment: String
    var enabled: Bool
    var enabledCookieJar: Bool
    var enableJs: Bool
    var loadWithBaseUrl: Bool
    var singleUrl: Bool
    var articleStyle: Int
    var customOrder: Int
    var type: Int
    var lastUpdateTime: Int

    var header: String
    var jsLib: String
    var loginUrl: String
    var loginUi: String
    var loginCheckJs: String
    var injectJs: String
    var preloadJs: String
    var startHtml: String
    var startStyle: String
    var startJs: String
    var style: String
    var preload: Bool
    var cacheFirst: Bool
    var showWebLog: Bool
    var shouldOverrideUrlLoading: String
    var contentWhitelist: String
    var contentBlacklist: String

    /// 分类列表："名称::地址" 换行分隔
    var sortUrl: String
    var searchUrl: String

    var ruleArticles: String
    var ruleNextPage: String
    var ruleTitle: String
    var rulePubDate: String
    var ruleDescription: String
    var ruleImage: String
    var ruleLink: String
    var ruleContent: String

    /// 订阅源声明原样透传给脚本。
    ///
    /// 与 `BookSource.metaJSON` 同因同构：脚本直接读自己声明里的字段，
    /// 全量语料实测订阅源侧有 `source.sourceIcon`（51 处）、
    /// `source.sourceComment`（135 处）、`source.loginUrl`（64 处）、
    /// `source.sortUrl`（17 处）等读取点。缺一个就是 undefined 参与运算 ——
    /// 而 `source.sourceIcon` 尤其典型：RSS 616「AI风月」的 ruleArticles 写
    /// `obj.img = source.sourceIcon`，图标取不到时整列文章封面全空。
    ///
    /// 可选类型：已落盘的旧订阅源没有这一列，非可选会让整份列表解码失败。
    var metaJSON: String?

    init(dict: [String: Any]) {
        let urlValue = dict.str("sourceUrl", "url", "baseUrl", "host") ?? ""
        let nameValue = dict.str("sourceName", "name", "title") ?? "未命名订阅源"
        id = dict.str("sourceKey", "key", "id", "sourceId") ?? (nameValue + "|" + urlValue).stableHash

        name = nameValue
        url = urlValue.trimmed
        icon = dict.str("sourceIcon", "icon", "iconUrl") ?? ""
        group = dict.str("sourceGroup", "group") ?? ""
        comment = dict.str("sourceComment", "comment", "desc") ?? ""
        enabled = dict.bool(true, "enabled", "enable")
        enabledCookieJar = dict.bool("enabledCookieJar", "cookieJar")
        enableJs = dict.bool("enableJs", "jsEnabled")
        loadWithBaseUrl = dict.bool(true, "loadWithBaseUrl")
        singleUrl = dict.bool("singleUrl")
        articleStyle = dict.int("articleStyle") ?? 0
        customOrder = dict.int("customOrder", "order", "sort") ?? 0
        type = dict.int("type") ?? 0
        lastUpdateTime = dict.int("lastUpdateTime", "updateTime") ?? 0

        header = dict.str("header", "headers") ?? ""
        jsLib = dict.str("jsLib") ?? ""
        loginUrl = dict.str("loginUrl") ?? ""
        loginUi = dict.str("loginUi") ?? ""
        loginCheckJs = dict.str("loginCheckJs") ?? ""
        injectJs = dict.str("injectJs") ?? ""
        preloadJs = dict.str("preloadJs") ?? ""
        startHtml = dict.str("startHtml") ?? ""
        startStyle = dict.str("startStyle") ?? ""
        startJs = dict.str("startJs") ?? ""
        style = dict.str("style") ?? ""
        preload = dict.bool("preload")
        cacheFirst = dict.bool("cacheFirst")
        showWebLog = dict.bool("showWebLog")
        shouldOverrideUrlLoading = dict.str("shouldOverrideUrlLoading") ?? ""
        contentWhitelist = dict.str("contentWhitelist") ?? ""
        contentBlacklist = dict.str("contentBlacklist") ?? ""

        sortUrl = dict.str("sortUrl") ?? ""
        searchUrl = dict.str("searchUrl") ?? ""

        ruleArticles = dict.str("ruleArticles") ?? ""
        ruleNextPage = dict.str("ruleNextPage") ?? ""
        ruleTitle = dict.str("ruleTitle") ?? ""
        rulePubDate = dict.str("rulePubDate") ?? ""
        ruleDescription = dict.str("ruleDescription") ?? ""
        ruleImage = dict.str("ruleImage") ?? ""
        ruleLink = dict.str("ruleLink") ?? ""
        ruleContent = dict.str("ruleContent") ?? ""
        metaJSON = RssSource.scalarMeta(dict)
    }

    /// 抽出订阅源声明里的标量字段并序列化成 JSON 文本。
    ///
    /// 与书源侧同规则：只留标量，规则字典与超长内联脚本排除 ——
    /// 后者体积是其余字段的上百倍，且已由 typed 属性承载。
    private static func scalarMeta(_ dict: [String: Any]) -> String {
        let excludedKeys: Set<String> = [
            "ruleArticles", "ruleNextPage", "ruleTitle", "rulePubDate",
            "ruleDescription", "ruleImage", "ruleLink", "ruleContent",
            "jsLib", "injectJs", "preloadJs", "startJs", "startHtml",
            "startStyle", "style", "sortUrl", "searchUrl"
        ]
        var output: [String: Any] = [:]
        for (key, value) in dict {
            if excludedKeys.contains(key) { continue }
            if let text = value as? String {
                if text.count > 8192 { continue }
                output[key] = text
            } else if let number = value as? NSNumber {
                // 必须用 CFBooleanGetTypeID 区分真假布尔：JSON 解析出来的 `true`
                // 是 __NSCFBoolean，同样是 NSNumber，当数字存会把 true/false
                // 写成 1/0，源里 `=== true` 对不上；反过来时间戳若被当 Bool
                // 就会变成 1。按类型 ID 判断两个方向都不会错。
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    output[key] = number.boolValue
                } else {
                    output[key] = number
                }
            } else if let flag = value as? Bool {
                output[key] = flag
            }
        }
        guard !output.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: output),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// 是否配置了列表规则；没有时退化为直接罗列页面链接
    var hasArticleRule: Bool { !ruleArticles.trimmed.isEmpty }

    var hasSearch: Bool { !searchUrl.trimmed.isEmpty }

    /// 解析 sortUrl 里的 "名称::相对地址" 列表
    var categories: [RssCategory] {
        var items: [RssCategory] = []
        var seen = Set<String>()
        for line in sortUrl.components(separatedBy: .newlines) {
            let value = line.trimmed
            guard !value.isEmpty, value.contains("::") else { continue }
            let parts = value.components(separatedBy: "::")
            let title = parts[0].trimmed
            var link = parts.count > 1 ? parts[1].trimmed : ""
            // 有些源在地址后跟了 #锚点 注释
            if let hash = link.firstIndex(of: "#") { link = String(link[..<hash]) }
            link = link.trimmed
            guard !title.isEmpty else { continue }
            let key = title + "|" + link
            if seen.contains(key) { continue }
            seen.insert(key)
            items.append(RssCategory(title: title, url: link))
        }
        return items
    }

    /// 列表地址：单条分类为空时回落到订阅源主页
    static func resolvedListURL(category: RssCategory?, source: RssSource) -> String {
        guard let category, !category.url.trimmed.isEmpty else { return source.url.trimmed }
        return RuleUtil.absoluteURL(category.url, base: source.url)
    }
}
