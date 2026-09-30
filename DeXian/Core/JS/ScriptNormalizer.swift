import Foundation

/// 脚本兼容性归一化：把「Legado 的 Rhino 能跑、但标准 JS 引擎不认」的写法
/// 改写成等价的标准写法。
///
/// 目前只处理一类，但它在真实书源里很集中：
///
/// ```js
/// arr.map([title, b] => { push(title, $$(a, b), 0.25); });
/// ```
///
/// 按 ES 规范，箭头函数的**参数若是解构模式，必须再加一层括号**：
/// 合法写法是 `([title, b]) => …`。Rhino 对此宽容，
/// 所以书源作者大量写成裸形式；而 JavaScriptCore（Safari / iOS）与 V8
/// 都会直接报 `Malformed arrow function parameter list`，整段脚本一行都不执行。
///
/// 实测新导入的 yckceo 书源里，212 个脚本型发现源中有 30 个栽在这里，
/// 表现就是那些源的发现页全空。
///
/// 归一化只在「原脚本已被判定为语法错误」时才启用（见 JSEngine.scriptCandidates），
/// 能正常解析的脚本一律原样求值，不会因为改写而改变行为。
enum ScriptNormalizer {

    /// 把裸的解构参数补上括号。没有任何改动时返回 nil。
    static func normalizeArrowParameters(_ script: String) -> String? {
        let characters = Array(script)
        var output = ""
        output.reserveCapacity(characters.count + 16)
        var index = 0
        var changed = false
        var quote: Character?
        var inLineComment = false
        var inBlockComment = false

        while index < characters.count {
            let character = characters[index]

            // --- 字符串 / 模板串：整段原样搬运，避免误改串里的内容 ---
            if let activeQuote = quote {
                output.append(character)
                if character == "\\", index + 1 < characters.count {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == activeQuote { quote = nil }
                index += 1
                continue
            }

            // --- 注释：同样整段搬运 ---
            if inLineComment {
                output.append(character)
                if character == "\n" { inLineComment = false }
                index += 1
                continue
            }
            if inBlockComment {
                output.append(character)
                if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    output.append("/")
                    index += 2
                    inBlockComment = false
                    continue
                }
                index += 1
                continue
            }
            if character == "/", index + 1 < characters.count {
                if characters[index + 1] == "/" {
                    inLineComment = true
                    output.append(character)
                    index += 1
                    continue
                }
                if characters[index + 1] == "*" {
                    inBlockComment = true
                    output.append(character)
                    index += 1
                    continue
                }
            }
            if character == "'" || character == "\"" || character == "`" {
                quote = character
                output.append(character)
                index += 1
                continue
            }

            // --- 候选解构模式 ---
            if character == "[" || character == "{",
               let end = patternEnd(characters, from: index),
               arrowFollows(characters, after: end),
               needsParentheses(characters, at: index) {
                output.append("(")
                output.append(contentsOf: characters[index...end])
                output.append(")")
                index = end + 1
                changed = true
                continue
            }

            output.append(character)
            index += 1
        }

        return changed ? output : nil
    }

    // MARK: 辅助

    /// 从 `start` 处的 `[` / `{` 起，找到配对的收尾下标。
    ///
    /// 只接受**简单绑定模式**：元素为标识符、或 `键: 标识符`、或嵌套的简单模式，
    /// 用逗号分隔（允许末尾多余逗号）。
    ///
    /// 刻意不支持更复杂的形态（默认值、rest、计算属性…）：它们在书源里没出现过，
    /// 而放宽匹配会误伤 `[1, 2]` 这类数组字面量。
    private static func patternEnd(_ characters: [Character], from start: Int) -> Int? {
        let open = characters[start]
        let close: Character = open == "[" ? "]" : "}"
        var index = start + 1
        var depth = 0
        var expectElement = true

        while index < characters.count {
            let character = characters[index]

            if character == "]" || character == "}" {
                if depth > 0 {
                    // 嵌套模式由内层负责校验，这里只维持深度
                    depth -= 1
                    index += 1
                    continue
                }
                guard character == close else { return nil }
                // 收尾处允许悬空逗号：[a, b,] 与空模式 [] / {} 都合法；
                // 中间出现连续逗号（[a,,b]）已在上面被挡掉。
                return index
            }
            if character == "[" || character == "{" {
                depth += 1
                index += 1
                continue
            }
            if character == "," {
                if depth == 0 {
                    guard !expectElement else { return nil }
                    expectElement = true
                }
                index += 1
                continue
            }
            if character == ":" {
                // 对象模式的 `键: 绑定`
                index += 1
                continue
            }
            if character.isLetter || character.isNumber || character == "_" || character == "$" {
                expectElement = false
                index += 1
                continue
            }
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                index += 1
                continue
            }
            // 出现 `=`（默认值）、`...`（rest）、`(`、字符串等一律放弃
            return nil
        }
        return nil
    }

    /// 模式结束后（跳过空白与换行）是不是 `=>`。
    private static func arrowFollows(_ characters: [Character], after end: Int) -> Bool {
        var index = end + 1
        while index < characters.count,
              characters[index] == " " || characters[index] == "\t" || characters[index] == "\n" {
            index += 1
        }
        guard index + 1 < characters.count else { return false }
        return characters[index] == "=" && characters[index + 1] == ">"
    }

    /// 判断这个模式需不需要补括号。
    ///
    /// - 前面不是 `(`：裸模式，必须补 —— `x = [a, b] => …`
    /// - 前面是 `(` 且再往前是标识符：那是**调用**的左括号，
    ///   例如 `arr.map([t, b] => …)`，也要补
    /// - 前面是 `(` 且再往前不是标识符：那已经是箭头参数的括号，
    ///   例如 `([a, b]) => …` 或 `f(([a, b]) => …)`，跳过
    private static func needsParentheses(_ characters: [Character], at index: Int) -> Bool {
        guard let previous = previousNonSpace(characters, before: index) else { return true }
        if characters[previous] != "(" { return true }
        guard let beforePrevious = previousNonSpace(characters, before: previous) else {
            // 位于开头：`([a, b]) => …` 已经合法
            return false
        }
        let candidate = characters[beforePrevious]
        let isIdentifier = candidate.isLetter || candidate.isNumber
            || candidate == "_" || candidate == "$"
        return isIdentifier
    }

    private static func previousNonSpace(_ characters: [Character], before index: Int) -> Int? {
        var cursor = index - 1
        while cursor >= 0 {
            let character = characters[cursor]
            if character != " " && character != "\t" && character != "\n" && character != "\r" {
                return cursor
            }
            cursor -= 1
        }
        return nil
    }
}
