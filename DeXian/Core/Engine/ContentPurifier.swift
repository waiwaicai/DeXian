import Foundation

/// 正文净化引擎。
///
/// 聚合三类来源，按顺序应用：
/// 1. 用户规则 —— 设置里维护的 JSON 规则，优先级最高；
/// 2. 书源规则 —— `ruleContent.replaceRegex`；
/// 3. 全局规则 —— 内置广告、更新提示、站内导航。
///
/// 用户规则支持：
/// - `{"name":"去推广","pattern":"正则","replacement":""}`
/// - `{"name":"标点","find":"文本","replace":"，"}`
/// - 单条正则字符串 `"广告文案"`
struct ContentPurifier {
    struct Rule: Codable {
        var name: String?
        var pattern: String?
        var find: String?
        var replacement: String?
        var replace: String?
        var enabled: Bool = true

        var resolvedReplacement: String {
            replacement ?? replace ?? ""
        }
    }

    private let sourceRule: String?
    private let userRules: [Rule]

    init(sourceRule: String?, userRulesJSON: String? = nil) {
        self.sourceRule = sourceRule?.nilIfBlank
        guard let data = userRulesJSON?.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            userRules = []
            return
        }
        if let array = value as? [[String: Any]] {
            userRules = array.compactMap { Self.rule(from: $0) }
        } else if let object = value as? [String: Any] {
            userRules = [Self.rule(from: object)].compactMap { $0 }
        } else if let array = value as? [String] {
            userRules = array.compactMap { raw in
                let pattern = NSRegularExpression.escapedPattern(for: raw)
                return Rule(name: nil, pattern: pattern, find: nil, replacement: nil, replace: nil, enabled: true)
            }
        } else {
            userRules = []
        }
    }

    private static func rule(from dict: [String: Any]) -> Rule? {
        var result = Rule(
            name: dict["name"] as? String,
            pattern: dict["pattern"] as? String,
            find: dict["find"] as? String,
            replacement: dict["replacement"] as? String,
            replace: dict["replace"] as? String,
            enabled: (dict["enabled"] as? Bool) ?? true
        )
        if result.pattern == nil, let find = dict["find"] as? String {
            result.pattern = NSRegularExpression.escapedPattern(for: find)
        }
        return result.pattern?.nilIfBlank == nil ? nil : result
    }

    var rules: [(name: String, pattern: String, replacement: String)] {
        var result: [(String, String, String)] = []
        for rule in userRules where rule.enabled {
            result.append((rule.name ?? "自定义规则", rule.pattern ?? "", rule.resolvedReplacement))
        }
        result.append(contentsOf: parsedSourceRules)
        for rule in builtinRules {
            result.append(rule)
        }
        return result
    }

    private var parsedSourceRules: [(name: String, pattern: String, replacement: String)] {
        guard let sourceRule else { return [] }
        var result: [(String, String, String)] = []
        for rule in RuleSyntax.splitTopLevel(sourceRule, separator: "\n") {
            if let range = rule.range(of: "##") {
                let pattern = String(rule[..<range.lowerBound])
                let replacement = String(rule[range.upperBound...])
                if !pattern.isEmpty { result.append(("书源规则", pattern, replacement)) }
            } else if !rule.isEmpty {
                result.append(("书源规则", rule, ""))
            }
        }
        return result
    }

    private var builtinRules: [(name: String, pattern: String, replacement: String)] {
        [
            ("推广链接", "(?i)\\[?(?:广告|推荐|合作|赞助|招商|首发|独家授权)(?:[:：])?\\s*(?:https?://|www\\.)\\S+", ""),
            ("站内提示", "本章未完，请点击下一页继续阅读|请记住本站域名|手机版阅读网址|加入书签，方便阅读|最快更新，无弹窗阅读|请收藏本站|最新章节请访问|本站最新网址|为了方便下次阅读|如果您觉得不错|点击下一页继续阅读", ""),
            ("推广行", "^\\s*(?:[\\u4e00-\\u9fa5A-Za-z0-9]{0,18}(?:广告|推广|推荐|赞助|招商|首发|独家授权)[\\u4e00-\\u9fa5A-Za-z0-9]{0,18}|\\S+(?:\\.com|\\.net|\\.cc|\\.org|\\.info|\\.xyz|\\.top|\\.vip)(?:\\/\\S*)?)\\s*$", ""),
            ("多余分隔", "^\\s*[-=_*·•~—]{3,}\\s*$", "")
        ]
    }

    func purify(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = RuleUtil.regexReplace(result, pattern: rule.pattern, replacement: rule.replacement)
        }
        // 收尾去掉只剩分隔符的空行，避免广告行删除后留下大量空白。
        result = result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        result = HTMLNode.collapseNewlines(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 源兼容诊断结果
enum SourceCompatibility {
    enum Result: Equatable {
        case ok
        case emptyContent
        case contentTooShort(Int)
        case invalid(reason: String)
        case error(String)
    }

    static func describe(_ result: Result) -> String {
        switch result {
        case .ok: return "内容正常"
        case .emptyContent: return "正文为空"
        case .contentTooShort(let count): return "正文过短（\(count) 字）"
        case .invalid(let reason): return reason
        case .error(let reason): return reason
        }
    }

    static var isRemovableReason: (String) -> Bool {
        { reason in
            ["正文为空", "正文过短", "域名解析失败", "无法连接服务器", "链接格式不支持",
             "不支持搜索", "搜索无结果", "服务器响应异常", "内容为空"]
                .contains { reason.contains($0) }
        }
    }
}
