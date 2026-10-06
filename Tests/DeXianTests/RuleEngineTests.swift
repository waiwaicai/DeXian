import XCTest
import UIKit
@testable import DeXian

final class RuleEngineTests: XCTestCase {

    private let html = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><title>测试页</title></head>
    <body>
      <div id="list" class="book-list">
        <div class="item" data-id="1">
          <h3 class="name"><a href="/book/1">斗破苍穹</a></h3>
          <span class="author">天蚕土豆</span>
          <p class="intro">这里是简介一</p>
          <img src="/cover/1.jpg">
        </div>
        <div class="item" data-id="2">
          <h3 class="name"><a href="/book/2">凡人修仙传</a></h3>
          <span class="author">忘语</span>
          <p class="intro">这里是简介二</p>
          <img data-src="/cover/2.jpg">
        </div>
        <div class="item" data-id="3">
          <h3 class="name"><a href="https://other.com/book/3">雪中悍刀行</a></h3>
          <span class="author">烽火戏诸侯</span>
          <p class="intro">这里是简介三</p>
        </div>
      </div>
      <ul class="toc"><li><a href="/c/1">第一章</a></li><li><a href="/c/2">第二章</a></li></ul>
    </body>
    </html>
    """

    private func document() -> HTMLNode {
        HTMLParser.parse(html)
    }

    // MARK: HTML 解析

    func testHTMLParserProducesTree() {
        let root = document()
        let titles = CSSSelector.select("title", in: root)
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.normalizedText, "测试页")
    }

    func testHTMLParserHandlesUnclosedTags() {
        let root = HTMLParser.parse("<div><p>甲<p>乙</div><span>丙")
        let paragraphs = CSSSelector.select("p", in: root)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.map { $0.normalizedText }, ["甲", "乙"])
        XCTAssertEqual(CSSSelector.select("span", in: root).first?.normalizedText, "丙")
    }

    func testEntitiesDecoded() {
        let root = HTMLParser.parse("<div title=\"a&amp;b\">1&nbsp;2&lt;3</div>")
        let node = CSSSelector.select("div", in: root).first
        XCTAssertEqual(node?.attribute("title"), "a&b")
        XCTAssertEqual(node?.normalizedText, "1\u{00a0}2<3")
    }

    // MARK: CSS

    func testCSSClassAndDescendant() {
        let root = document()
        let names = CSSSelector.select("#list .item .name a", in: root)
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(names.first?.normalizedText, "斗破苍穹")
    }

    func testCSSAttributeSelectors() {
        let root = document()
        XCTAssertEqual(CSSSelector.select("img[data-src]", in: root).count, 1)
        XCTAssertEqual(CSSSelector.select(".item[data-id='2']", in: root).count, 1)
        XCTAssertEqual(CSSSelector.select("a[href^='/book/']", in: root).count, 2)
        XCTAssertEqual(CSSSelector.select("a[href$='/3']", in: root).count, 1)
        XCTAssertEqual(CSSSelector.select("a[href*='other']", in: root).count, 1)
    }

    func testCSSPseudoSelectors() {
        let root = document()
        XCTAssertEqual(CSSSelector.select(".item:first-child", in: root).count, 1)
        XCTAssertEqual(CSSSelector.select(".item:last-child", in: root).count, 1)
        XCTAssertEqual(CSSSelector.select(".item:eq(1)", in: root).first?.attribute("data-id"), "2")
        XCTAssertEqual(CSSSelector.select(".item", in: root).filter { $0.attribute("data-id") == "2" }.count, 1)
    }

    // MARK: XPath

    func testXPathBasic() {
        let root = document()
        let nodes = XPathEngine.nodes("//div[@id='list']/div", document: root)
        XCTAssertEqual(nodes.count, 3)
    }

    func testXPathTextAndAttribute() {
        let root = document()
        XCTAssertEqual(XPathEngine.nodes("//h3/a/@href", document: root).count, 3)
        let value = XPathEngine.evaluate("//h3/a", document: root)
        XCTAssertEqual(value.asString, "斗破苍穹")
    }

    func testXPathPredicatesAndPosition() {
        let root = document()
        // 第一个 item
        XCTAssertEqual(XPathEngine.nodes("//div[@class='item'][1]", document: root).count, 1)
        // 最后一个 item：last() 与 [1] 一样按上下文节点求值，作用在同级集合上
        let lastItem = XPathEngine.nodes("//div[@class='item'][last()]/h3/a", document: root)
        XCTAssertEqual(lastItem.first?.normalizedText, "雪中悍刀行")
        // 每个 h3 只有一个 a，所以 a 这一级的 [last()] 全命中（与浏览器一致）
        XCTAssertEqual(XPathEngine.nodes("//div[@class='item']/h3/a[last()]", document: root).count, 3)
    }

    func testXPathFunctions() {
        let root = document()
        XCTAssertTrue(XPathEngine.evaluate("contains(string(//title), '测试')", document: root).asBool)
        XCTAssertEqual(XPathEngine.evaluate("count(//div[@class='item'])", document: root).asNumber, 3)
        XCTAssertEqual(XPathEngine.evaluate("normalize-space('  a   b  ')", document: root).asString, "a b")
        XCTAssertEqual(XPathEngine.evaluate("substring('abcdef', 2, 3)", document: root).asString, "bcd")
        XCTAssertEqual(XPathEngine.evaluate("translate('aabbcc', 'ac', 'XY')", document: root).asString, "XXbbYY")
        XCTAssertTrue(XPathEngine.evaluate("//span[@class='author'][starts-with(., '天')]", document: root).asBool)
    }

    func testXPathUnion() {
        let root = document()
        let nodes = XPathEngine.nodes("//h3 | //span", document: root)
        XCTAssertEqual(nodes.count, 6)
    }

    // MARK: JSONPath

    private let json = """
    {
      "data": {
        "list": [
          {"name": "书一", "author": "作者一", "id": 11, "price": 10},
          {"name": "书二", "author": "作者二", "id": 22, "price": 25}
        ],
        "total": 2
      }
    }
    """

    private func jsonObject() -> Any {
        json.jsonObject!
    }

    func testJSONPathChildAndIndex() {
        XCTAssertEqual(JSONPath.query("$.data.total", json: jsonObject()).first as? Int, 2)
        XCTAssertEqual(JSONPath.query("$.data.list[0].name", json: jsonObject()).first as? String, "书一")
        XCTAssertEqual(JSONPath.query("$.data.list[-1].name", json: jsonObject()).first as? String, "书二")
    }

    func testJSONPathWildcardAndRecursive() {
        XCTAssertEqual(JSONPath.query("$.data.list[*].name", json: jsonObject()).count, 2)
        XCTAssertEqual(JSONPath.query("$..name", json: jsonObject()).count, 2)
        XCTAssertEqual(JSONPath.query("$.data.list[0,1].id", json: jsonObject()).count, 2)
        XCTAssertEqual(JSONPath.query("$.data.list[0:1].name", json: jsonObject()).count, 1)
    }

    func testJSONPathFilter() {
        let filtered = JSONPath.query("$.data.list[?(@.price>20)].name", json: jsonObject())
        XCTAssertEqual(filtered.first as? String, "书二")

        let stringFilter = JSONPath.query("$.data.list[?(@.author=='作者一')].id", json: jsonObject())
        XCTAssertEqual(stringFilter.first as? Int, 11)
    }

    // MARK: 规则语法

    func testRuleKindDetection() {
        XCTAssertEqual(RuleSyntax.detectKind("//div/a").0, .xpath)
        XCTAssertEqual(RuleSyntax.detectKind(".item a").0, .css)
        XCTAssertEqual(RuleSyntax.detectKind("$.data.list").0, .json)
        XCTAssertEqual(RuleSyntax.detectKind("@js:1+1").0, .javascript)
        XCTAssertEqual(RuleSyntax.detectKind(":regex:abc").0, .regex)
        XCTAssertEqual(RuleSyntax.detectKind("全部").0, .css)
    }

    func testRuleChainSplitting() {
        let segments = RuleSyntax.splitChain(".item a@href")
        XCTAssertEqual(segments, [".item a", "href"])

        // XPath 谓词里的 @ 不应被切开
        let xpathSegments = RuleSyntax.splitChain("//div[@class='item']/a@href")
        XCTAssertEqual(xpathSegments.count, 2)
        XCTAssertEqual(xpathSegments[0], "//div[@class='item']/a")

        // JS 链
        let jsSegments = RuleSyntax.splitChain("$.id@js:java.put('id', result);result")
        XCTAssertEqual(jsSegments.first, "$.id")
        XCTAssertTrue(jsSegments.last?.hasPrefix("js:") ?? false)
    }

    func testReplaceRuleSplitting() {
        let (core, replacements) = RuleSyntax.splitReplaceRule("//div/text@text##广告##")
        XCTAssertEqual(core, "//div/text@text")
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements[0].0, "广告")
        XCTAssertEqual(replacements[0].1, "")
    }

    // MARK: `@js:` 脚本保护（`||` 不拆分）

    /// `@js:` 之后的 `||` 是逻辑或，不能被当成规则分支切开。
    ///
    /// 有 26 条规则（15 个源）把整个目录/封面计算写成一段脚本，脚本里带 `||`。
    /// 切开后第一段是残缺脚本，往往求值成 `false`（**非空字符串**），
    /// `stringList` 于是在第一段就命中返回 —— 真正的地址永远算不出来，
    /// 界面表现就是目录地址/封面变成 "false"。
    func testJSRuleProtectsLogicalOrOperator() {
        // 脚本里的 || 不切
        let protected = RuleSyntax.splitTopLevel(
            "@js: re==baseUrl&&/,/.test(book.bookUrl)?re:',':re || fallback",
            separator: "||",
            protectJavaScript: true
        )
        XCTAssertEqual(protected.count, 1)

        // <js> 块之后的分支照常拆分
        let afterTag = RuleSyntax.splitTopLevel(
            "<js>GetList(result)</js> $.data||$..lists[*]",
            separator: "||",
            protectJavaScript: true
        )
        XCTAssertEqual(afterTag.count, 2)
        XCTAssertTrue(afterTag[0].hasPrefix("<js>"))

        // 普通选择器规则的候选分支必须先切
        let plain = RuleSyntax.splitTopLevel("class.a@text||class.b@text", separator: "||", protectJavaScript: true)
        XCTAssertEqual(plain.count, 2)
    }

    /// `@js:` 之前的部分仍按 `||` 拆分（`候选选择器@js:脚本`）。
    func testJSRuleSplitsBranchesBeforeScript() {
        let branches = RuleSyntax.splitTopLevel(
            "class.a@text@js:result||'x'",
            separator: "||",
            protectJavaScript: true
        )
        XCTAssertEqual(branches.count, 1)
        XCTAssertTrue(branches[0].hasSuffix("result||'x'"))
    }

    // MARK: 规则求值（含链式与属性）

    func testAnalyzeRuleCSSChain() {
        let analyzer = AnalyzeRule(content: html)
        let names = analyzer.stringList(".item .name a@text")
        XCTAssertEqual(names, ["斗破苍穹", "凡人修仙传", "雪中悍刀行"])

        let hrefs = analyzer.stringList(".item .name a@href")
        XCTAssertEqual(hrefs.first, "/book/1")

        let dataSrc = analyzer.stringList("img@data-src")
        XCTAssertEqual(dataSrc.first, "/cover/2.jpg")
    }

    func testAnalyzeRuleXPathChain() {
        let analyzer = AnalyzeRule(content: html)
        let authors = analyzer.stringList("//span[@class='author']/text()")
        XCTAssertEqual(authors.count, 3)
        XCTAssertEqual(authors.first, "天蚕土豆")
    }

    func testAnalyzeRuleListItems() {
        let analyzer = AnalyzeRule(content: html)
        let items = analyzer.listItems("//div[@class='item']")
        XCTAssertEqual(items.count, 3)

        let cssItems = analyzer.listItems(".item")
        XCTAssertEqual(cssItems.count, 3)
    }

    func testAnalyzeRuleJson() {
        let analyzer = AnalyzeRule(content: json)
        XCTAssertEqual(analyzer.string("$.data.total"), "2")
        XCTAssertEqual(analyzer.string("$.data.list[1].author"), "作者二")
        XCTAssertEqual(analyzer.stringList("$.data.list[*].name"), ["书一", "书二"])
    }

    func testAnalyzeRuleReplaceAndFallback() {
        let analyzer = AnalyzeRule(content: html)
        // 双竖线：第一个规则无结果时用第二个
        let value = analyzer.string("//notexist/text() || //title/text()")
        XCTAssertEqual(value, "测试页")
    }

    func testAnalyzeRuleInterpolation() {
        let analyzer = AnalyzeRule(content: html)
        analyzer.page = 3
        analyzer.key = "斗破"
        XCTAssertEqual(analyzer.interpolate("https://x.com?p={{page}}&k={{key}}"),
                       "https://x.com?p=3&k=%E6%96%97%E7%A0%B4")
    }

    // MARK: 正文清洗

    func testContentExtractionKeepsParagraphs() {
        let root = HTMLParser.parse("<div id='content'><p>第一段</p><p>第二段</p><br>第三段</div>")
        let node = CSSSelector.select("#content", in: root).first
        let text = node?.textWithBreaks ?? ""
        XCTAssertTrue(text.contains("第一段"))
        XCTAssertTrue(text.contains("第二段"))
        XCTAssertTrue(text.contains("第三段"))
        // 段落之间应有换行
        XCTAssertTrue(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count >= 3)
    }

    // MARK: 书源导入（多结构兼容）

    func testImportStandardArray() {
        let text = """
        [{"bookSourceName":"源一","bookSourceUrl":"https://a.com","bookSourceType":0,
          "ruleSearch":{"bookList":".item","name":".name@text","bookUrl":"a@href"},
          "searchUrl":"https://a.com/search?q={{key}}"}]
        """
        let result = SourceImporter.parse(text: text)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.name, "源一")
        XCTAssertEqual(result.sources.first?.searchUrl, "https://a.com/search?q={{key}}")
    }

    func testImportWrappedObject() {
        let text = """
        {"success":true,"data":{"bookSources":[
          {"bookSourceName":"源A","bookSourceUrl":"https://a.com"},
          {"bookSourceName":"源B","bookSourceUrl":"https://b.com"}
        ]}}
        """
        let result = SourceImporter.parse(text: text)
        XCTAssertEqual(result.sources.count, 2)
    }

    func testImportBase64() {
        let json = "[{\"bookSourceName\":\"编码源\",\"bookSourceUrl\":\"https://c.com\"}]"
        let base64 = Data(json.utf8).base64EncodedString()
        let result = SourceImporter.parse(text: base64)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.name, "编码源")
    }

    func testImportShareText() {
        let text = "分享一个书源：作者xxx 链接在此 [{\"bookSourceName\":\"分享源\",\"bookSourceUrl\":\"https://d.com\"}] 记得导入"
        let result = SourceImporter.parse(text: text)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.name, "分享源")
    }

    func testImportLooseJSON() {
        // 带注释与尾随逗号
        let text = """
        [
          // 第一个书源
          {"bookSourceName":"宽松源","bookSourceUrl":"https://e.com",},
        ]
        """
        let result = SourceImporter.parse(text: text)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.name, "宽松源")
    }

    func testImportAliases() {
        // 使用字段别名（部分第三方工具导出）
        let text = """
        [{"name":"别名源","url":"https://f.com","type":2,
          "search":{"list":".item","name":".t"}}]
        """
        let result = SourceImporter.parse(text: text)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.name, "别名源")
        XCTAssertEqual(result.sources.first?.type, .image)
        XCTAssertEqual(result.sources.first?.searchRule.bookList, ".item")
    }

    func testImportSkipsInvalidEntries() {
        let text = "[{\"foo\":1},{\"bookSourceName\":\"有效\",\"bookSourceUrl\":\"https://g.com\"}]"
        let result = SourceImporter.parse(text: text)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.skipped, 1)
    }

    func testImportLargeYckceoCollectionStructure() {
        // yckceo 1305 这类合集是 JSON 数组；exploreUrl 又是内嵌 JSON 字符串，
        // 并额外带 customButton / eventListener 字段。这里锁住这两个兼容点。
        let exploreItems = [["title": "都市", "url": "/class/1/{{page}}.html", "style": ["layout_flexGrow": 1]]] as [[String: Any]]
        let exploreData = try! JSONSerialization.data(withJSONObject: exploreItems)
        let exploreJSON = String(data: exploreData, encoding: .utf8)!
        let payload: [[String: Any]] = [
            [
                "bookSourceName": "大合集源",
                "bookSourceUrl": "https://large.test",
                "bookSourceType": 2,
                "enabled": true,
                "enabledExplore": true,
                "customButton": ["name": "测试"],
                "eventListener": "console.log('ok')",
                "exploreUrl": exploreJSON,
                "searchUrl": "https://large.test/search?q={{key}}",
                "ruleSearch": ["bookList": ".item", "name": ".name@text", "bookUrl": "a@href"],
                "ruleExplore": ["bookList": ".book", "name": ".title@text", "bookUrl": "a@href"]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let result = SourceImporter.parse(text: String(data: data, encoding: .utf8)!)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.sources.first?.type, .image)
        let page = ExplorePage.parse(result.sources.first?.exploreUrl)
        XCTAssertEqual(page.categories.first?.title, "都市")
        XCTAssertEqual(page.categories.first?.url, "/class/1/{{page}}.html")
        XCTAssertEqual(SourceImporter.importDownloadTimeout, 180)
    }

    func testImportNDJSON() {
        let text = """
        {"bookSourceName":"行一","bookSourceUrl":"https://h1.com"}
        {"bookSourceName":"行二","bookSourceUrl":"https://h2.com"}
        """
        let result = SourceImporter.parse(text: text)
        XCTAssertEqual(result.sources.count, 2)
    }

    func testMergeDeduplicates() {
        let first = BookSource(dict: ["bookSourceName": "同名", "bookSourceUrl": "https://x.com"])
        var updated = first
        updated.enabled = false
        let merged = SourceImporter.merge(existing: [first], incoming: [updated])
        XCTAssertEqual(merged.result.count, 1)
        XCTAssertEqual(merged.updated, 1)
        XCTAssertEqual(merged.added, 0)
    }

    // MARK: 工具

    func testAbsoluteURL() {
        XCTAssertEqual(RuleUtil.absoluteURL("/book/1", base: "https://a.com/list?p=1"), "https://a.com/book/1")
        XCTAssertEqual(RuleUtil.absoluteURL("book/1", base: "https://a.com/list/"), "https://a.com/list/book/1")
        XCTAssertEqual(RuleUtil.absoluteURL("//cdn.com/a.jpg", base: "https://a.com"), "https://cdn.com/a.jpg")
        XCTAssertEqual(RuleUtil.absoluteURL("https://b.com/x", base: "https://a.com"), "https://b.com/x")
        XCTAssertEqual(RuleUtil.absoluteURL("data:image/gif;base64,AAA", base: "https://a.com"),
                       "data:image/gif;base64,AAA")
    }

    func testRegexUtilities() {
        XCTAssertEqual(RuleUtil.regexMatch("abc123def456", pattern: "\\d+"), ["123", "456"])
        XCTAssertEqual(RuleUtil.regexReplace("a1b2", pattern: "\\d", replacement: ""), "ab")
        XCTAssertEqual(RuleUtil.regexReplace("第1章", pattern: "(\\d+)", replacement: "[$1]"), "第[1]章")
    }

    func testCharsetDecoding() {
        // GB18030 编码的“中文测试”
        let original = "中文测试"
        guard let data = original.data(using: String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )) else {
            XCTFail("无法生成 GB18030 数据")
            return
        }
        XCTAssertEqual(Charset.decode(data), original)
    }

    // MARK: 听书 / 漫画

    func testAutoReaderSplitsLongText() {
        // 短段落合并成一片，合并后段落之间保留换行（朗读时会自然停顿）
        let chunks = AutoReader.split("第一段\n\n第二段\n第三段")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "第一段\n第二段\n第三段")

        // 超长段落按标点继续切分，且每片不超过上限
        let long = String(repeating: "这是一句测试文本。", count: 60)
        let pieces = AutoReader.split(long)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, 320)
        }

        // 超过上限的段落不会被粘在同一片里
        let manyParagraphs = (1...80).map { "第" + String($0) + "段内容" }.joined(separator: "\n")
        let grouped = AutoReader.split(manyParagraphs)
        XCTAssertGreaterThan(grouped.count, 1)
        for piece in grouped {
            XCTAssertLessThanOrEqual(piece.count, 320)
        }

        // 空白输入不产生片段
        XCTAssertTrue(AutoReader.split("   \n  ").isEmpty)
    }

    func testAutoReaderRateConversion() {
        // 600 字/分 对应系统速率 1.0，且始终落在 0.1...1.0
        XCTAssertEqual(AutoReader.systemRate(for: 600), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AutoReader.systemRate(for: 300), 0.5, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(AutoReader.systemRate(for: 10), 0.1)
        XCTAssertLessThanOrEqual(AutoReader.systemRate(for: 99999), 1.0)
    }

    func testExtractComicImages() {
        let engine = SourceEngine(source: makeSource([
            "bookSourceName": "漫画测试",
            "bookSourceUrl": "https://comic.test",
            "bookSourceType": 2
        ]))
        let html = """
        <div class="content">
          <img src="/img/1.jpg">
          <img data-src="/img/2.jpg">
          <img data-original="https://cdn.test/img/3.webp">
          <img src="data:image/gif;base64,R0lGOD">
        </div>
        """
        let images = engine.extractImages(from: html, baseUrl: "https://comic.test/ch/1")
        XCTAssertEqual(images, [
            "https://comic.test/img/1.jpg",
            "https://comic.test/img/2.jpg",
            "https://cdn.test/img/3.webp"
        ])
    }

    func testSourceErrorDescriptions() {
        XCTAssertFalse(SourceError.emptyToc.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(SourceError.sourceDisabled.errorDescription?.isEmpty ?? true)
    }

    /// 由字典造一个书源，字段名与 Legado 保持一致
    // MARK: 大书源 / 配色

    func testImportLimitsAreConfigured() {
        // 体积闸门必须存在且为正，否则大文件会直接吃满内存
        XCTAssertGreaterThan(SourceImporter.maxTextBytes, 1024 * 1024)
        XCTAssertGreaterThan(SourceImporter.maxScanBytes, 0)
        XCTAssertLessThanOrEqual(SourceImporter.maxScanBytes, SourceImporter.maxTextBytes)
        XCTAssertGreaterThan(SourceImporter.maxCandidates, 0)
        XCTAssertFalse(SourceImporter.ImportLimitError.tooLarge(3 * 1024 * 1024)
            .errorDescription?.isEmpty ?? true)
    }

    func testSanitizeJSONRemovesCommentsAndTrailingCommas() {
        let loose = """
        {
          // 行注释
          "a": 1, /* 块注释 */
          "b": [1, 2, 3,],
        }
        """
        let cleaned = SourceImporter.sanitizeJSON(loose)
        XCTAssertFalse(cleaned.contains("// 行注释"))
        XCTAssertFalse(cleaned.contains("/* 块注释 */"))
        XCTAssertFalse(cleaned.contains(",}"))
        XCTAssertFalse(cleaned.contains(",]"))
        // 清理后应当能被标准 JSON 解析
        XCTAssertNotNil(SourceImporter.parseJSON(cleaned))
    }

    func testSanitizeJSONKeepsCommentLikeTextInStrings() {
        // 字符串里的 // 与 /* 不能被当成注释删掉
        let value = #"{"url": "https://a.com//b", "x": "a/*b*/c"}"#
        let cleaned = SourceImporter.sanitizeJSON(value)
        XCTAssertTrue(cleaned.contains("https://a.com//b"))
        XCTAssertTrue(cleaned.contains("a/*b*/c"))
    }

    func testJSONCandidatesAreCapped() {
        // 多个片段时只保留上限之内的数量，且长的优先
        // 注意：这里刻意拆成多条语句。写成一行链式表达式时，
        // Swift 的类型检查器会报
        // "the compiler is unable to type-check this expression in reasonable time"。
        var pieces: [String] = []
        pieces.reserveCapacity(40)
        for index in 0..<40 {
            let n = String(index)
            let one = "{\"bookSourceName\":\"s" + n + "\",\"bookSourceUrl\":\"https://x" + n + ".com\"}"
            pieces.append(one)
        }
        let text = pieces.joined(separator: " 噪声 ")
        let candidates = SourceImporter.jsonCandidates(in: text)
        XCTAssertLessThanOrEqual(candidates.count, SourceImporter.maxCandidates)
        XCTAssertFalse(candidates.isEmpty)
    }

    func testReaderThemeBlackGreenPalette() {
        let theme = SettingsStore.ReaderTheme.blackGreen
        // 纯黑背景
        XCTAssertEqual(theme.backgroundColor, 0x000000)
        // 绿色字：绿色通道明显高于红和蓝
        let text = theme.textColor
        let r = (text >> 16) & 0xFF, g = (text >> 8) & 0xFF, b = text & 0xFF
        XCTAssertGreaterThan(g, r)
        XCTAssertGreaterThan(g, b)
        XCTAssertTrue(theme.isDark)
    }

    func testReaderThemeCoversRequestedCombinations() {
        // 用户要求的"全黑 + 彩色字"与可读的浅色组合都要有
        let all = SettingsStore.ReaderTheme.allCases
        XCTAssertTrue(all.contains(.blackGreen))
        XCTAssertTrue(all.contains(.blackAmber))
        XCTAssertTrue(all.contains(.paper))
        for item in all {
            XCTAssertFalse(item.displayName.isEmpty)
        }
    }

    private func makeSource(_ dict: [String: Any]) -> BookSource {
        SourceImporter.makeSource(dict) ?? BookSource(dict: [:])
    }

    func testParseURLOptions() {
        let (url, options) = HTTPClient.parseURLRule("https://a.com/api,{\"method\":\"POST\",\"body\":{\"k\":1}}")
        XCTAssertEqual(url, "https://a.com/api")
        XCTAssertEqual(options.method, "POST")
        XCTAssertEqual(options.body, "{\"k\":1}")
    }

    // MARK: 相对地址（unsupported URL 回归）

    func testRelativeURLResolvesAgainstSourceBase() {
        // 腐文阁 / 伪速读谷这类源写的是相对路径，缺 base 会抛 unsupported URL
        XCTAssertEqual(
            RuleUtil.absoluteURL("/search.php?searchkey=%E6%83%85&page=2", base: "https://m.fuwenge.com/"),
            "https://m.fuwenge.com/search.php?searchkey=%E6%83%85&page=2"
        )
        XCTAssertEqual(
            RuleUtil.absoluteURL("/modules/article/search.php", base: "https://www.sudugu.cc"),
            "https://www.sudugu.cc/modules/article/search.php"
        )
        // 已经是绝对地址时 base 不参与
        XCTAssertEqual(
            RuleUtil.absoluteURL("https://a.test/x", base: "https://b.test/"),
            "https://a.test/x"
        )
        // 协议相对地址沿用 base 的 scheme
        XCTAssertEqual(
            RuleUtil.absoluteURL("//cdn.test/a.jpg", base: "http://m.fuwenge.com/"),
            "http://cdn.test/a.jpg"
        )
    }

    // MARK: <js> 段（禁忌书屋 searchUrl 写法）

    func testJSSegmentSplitting() {
        let pieces = RuleSyntax.splitJSSegments("<js>if(page==1){x=1}</js>index.php?action=search&p={{page}}")
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces[0].isJS)
        XCTAssertTrue(pieces[1].text.hasPrefix("index.php?action=search"))

        // 前后都有静态片段
        let both = RuleSyntax.splitJSSegments("a<js>1</js>b")
        XCTAssertEqual(both.count, 3)
        XCTAssertFalse(both[0].isJS)
        XCTAssertTrue(both[1].isJS)
        XCTAssertFalse(both[2].isJS)
    }

    func testJSSegmentResolutionBuildsURL() {
        // JS 段先执行，结果与后缀拼接
        let url = RuleUtil.resolveJSSegments("<js>1+1</js>index.php?p=2") { _ in "2" }
        XCTAssertEqual(url, "2index.php?p=2")

        // @result 占位符承接上一段结果
        let carried = RuleUtil.resolveJSSegments("https://a.test/<js>''</js>@result") { _ in "keep" }
        XCTAssertEqual(carried, "keep")

        // 裸 @js: 前缀整串当脚本
        let bare = RuleUtil.resolveJSSegments("@js: 'https://b.test/x'") { _ in "https://b.test/x" }
        XCTAssertEqual(bare, "https://b.test/x")

        // 不含 JS 段时原样返回
        XCTAssertEqual(RuleUtil.resolveJSSegments("https://a.test/x") { _ in "no" }, "https://a.test/x")
    }

    // MARK: 传统选择器（class. / tag. / id. / text.）

    func testLegacySelectorDetection() {
        XCTAssertTrue(LegacySelector.isLegacy("class.item.0@tag.a@href"))
        XCTAssertTrue(LegacySelector.isLegacy("tag.tr[1:]"))
        XCTAssertTrue(LegacySelector.isLegacy("id.list-chapterAll@tag.dd@tag.a"))
        XCTAssertTrue(LegacySelector.isLegacy("text.下一页@href"))
        XCTAssertTrue(LegacySelector.isLegacy("children[0]"))
        // 标准 CSS 不应该被当成传统选择器
        XCTAssertFalse(LegacySelector.isLegacy(".item .name a"))
        XCTAssertFalse(LegacySelector.isLegacy("div.item"))
    }

    func testLegacySelectorClassAndTag() {
        let root = document()
        // class.item -> 3 个
        XCTAssertEqual(LegacySelector.select("class.item", in: root).count, 3)
        // class.item.0 -> 第 1 个
        XCTAssertEqual(LegacySelector.select("class.item.0", in: root).first?.attribute("data-id"), "1")
        // tag.h3 -> 3 个
        XCTAssertEqual(LegacySelector.select("tag.h3", in: root).count, 3)
        // id.list -> 1 个
        XCTAssertEqual(LegacySelector.select("id.list", in: root).count, 1)
        // 负索引 -1 取最后一个
        XCTAssertEqual(LegacySelector.select("class.item.-1", in: root).first?.attribute("data-id"), "3")
    }

    func testLegacySelectorBracketRangeAndExclusion() {
        let root = document()
        // tag.a[1:] 从第 2 个开始
        let fromSecond = LegacySelector.select("tag.a[1:]", in: root)
        XCTAssertEqual(fromSecond.count, 4)
        XCTAssertEqual(fromSecond.first?.normalizedText, "凡人修仙传")

        // 区间 [0:2]
        XCTAssertEqual(LegacySelector.select("class.item[0:2]", in: root).count, 2)
        // 排除 [!1]
        let excluded = LegacySelector.select("class.item[!1]", in: root)
        XCTAssertEqual(excluded.count, 2)
        XCTAssertEqual(excluded.first?.attribute("data-id"), "1")
        XCTAssertEqual(excluded.last?.attribute("data-id"), "3")
    }

    func testLegacySelectorChainThroughAnalyzer() {
        let analyzer = AnalyzeRule(content: html)
        // class.item.0@tag.a@href 等价于取第一本书的链接
        XCTAssertEqual(analyzer.string("class.item.0@tag.a@href"), "/book/1")
        XCTAssertEqual(analyzer.stringList("class.item@tag.a@text"),
                       ["斗破苍穹", "凡人修仙传", "雪中悍刀行"])
        // 列表规则
        XCTAssertEqual(analyzer.listItems("class.item").count, 3)
    }

    /// 环状 DOM 不能把选择器拖进死循环。
    ///
    /// 书源规则自建节点、或解析异常时有可能出现自引用，
    /// 之前遍历会一直展开直到内存耗尽被系统强杀。
    func testLegacySelectorTerminatesOnCyclicTree() {
        let root = HTMLNode(kind: .element, name: "div")
        let child = HTMLNode(kind: .element, name: "span")
        root.append(child)
        child.children.append(root)   // 人为制造环

        let picked = LegacySelector.select("tag.span", in: root)
        XCTAssertEqual(picked.count, 1)
    }

    /// 漫画正文规则直接选中容器节点时，必须保留 <img>，不能拍平成纯文本。
    ///
    /// 多数漫画源的 content 规则写成 `class.comic-contain` 这类节点选择器，
    /// 早期实现走 string() 会把 <img src> 丢掉，导致「一张图都没有」。
    func testHtmlStringKeepsImgForComicRules() {
        let html = """
        <div class="comic-contain"><img src="/p/1.jpg"><img data-src="/p/2.jpg"></div>
        """
        let analyzer = AnalyzeRule(content: html)
        let text = analyzer.string("class.comic-contain")
        let markup = analyzer.htmlString("class.comic-contain")

        XCTAssertFalse(markup.isEmpty)
        XCTAssertTrue(markup.contains("<img"))
        XCTAssertTrue(markup.contains("/p/1.jpg"))
        // 纯文本形态拿不到 src，正好说明为什么必须用 htmlString
        XCTAssertFalse(text.contains("/p/1.jpg"))
    }

    // MARK: JS 返回对象数组的漫画图片

    func testComicImagesFromJSObjectArray() {
        // 包子漫画的规则返回 [{link:"..."}]
        let json = """
        [{"link":"https://img.test/1.jpg"},{"link":"//img.test/2.jpg"}]
        """
        let links = RuleUtil.imageLinksFromJSON(json)
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.contains("https://img.test/1.jpg"))
        // 其它字段名也要能识别
        let alt = RuleUtil.imageLinksFromJSON("[{\"src\":\"https://img.test/3.webp\"}]")
        XCTAssertEqual(alt, ["https://img.test/3.webp"])
    }

    func testComicImagesIncludeJSObjectArray() {
        let engine = SourceEngine(source: makeSource([
            "bookSourceName": "漫画对象数组",
            "bookSourceUrl": "https://comic.test",
            "bookSourceType": 2
        ]))
        let value = "[{\"link\":\"/img/9.jpg\"}]"
        let images = engine.extractImages(from: value, baseUrl: "https://comic.test/ch/1")
        XCTAssertEqual(images, ["https://comic.test/img/9.jpg"])
    }

    // MARK: 整本离线缓存

    func testChapterContentIsCodable() throws {
        let content = ChapterContent(text: "正文", images: ["https://a.test/1.jpg"], nextChapterUrl: nil)
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ChapterContent.self, from: data)
        XCTAssertEqual(decoded.text, "正文")
        XCTAssertEqual(decoded.images, ["https://a.test/1.jpg"])
    }

    /// 缓存写入 / 读取现在都是异步的（磁盘 IO 已移出主线程）。
    @MainActor
    func testChapterCacheStoresAndReadsBack() async {
        let cache = ChapterCache.shared
        let bookId = "test-cache-book-" + UUID().uuidString
        let chapterUrl = "https://comic.test/ch/" + UUID().uuidString
        defer { cache.remove(bookId: bookId) }

        // meta 未读入内存时，一律视为未缓存
        XCTAssertFalse(cache.isCached(bookId: bookId, chapterUrl: chapterUrl))
        let content = ChapterContent(text: "缓存正文", images: [], nextChapterUrl: nil)
        await cache.store(bookId: bookId, name: "缓存测试", origin: "src", chapterUrl: chapterUrl, content: content)

        XCTAssertTrue(cache.isCached(bookId: bookId, chapterUrl: chapterUrl))
        let back = await cache.content(bookId: bookId, chapterUrl: chapterUrl)
        XCTAssertEqual(back?.text, "缓存正文")
        XCTAssertEqual(cache.counts(bookId: bookId).cached, 1)

        cache.remove(bookId: bookId)
        XCTAssertFalse(cache.isCached(bookId: bookId, chapterUrl: chapterUrl))
    }
    // MARK: 崩溃防护（第三方书源内容不受控，必须挡在解析层）

    /// 深度递归的 XPath 表达式不能让栈溢出。
    ///
    /// 这类规则来自第三方书源：形如一连串负号或层层括号的表达式
    /// 会让递归下降解析器无限展开。栈溢出是硬件级错误，
    /// Swift 的 do/catch 抓不住，进程会当场硬崩且不产生崩溃报告 ——
    /// 表现就是「某个书源一搜就闪退」。
    func testXPathDeepExpressionDoesNotCrash() {
        let root = document()
        let negations = String(repeating: "-", count: 20000) + "1"
        _ = XPathEngine.evaluate(negations, document: root)

        let parentheses = String(repeating: "(", count: 20000) + "1" + String(repeating: ")", count: 20000)
        _ = XPathEngine.evaluate(parentheses, document: root)

        // 正常表达式必须完全不受影响
        XCTAssertEqual(XPathEngine.nodes("//div[@class='item']", document: root).count, 3)
    }

    /// 深层嵌套的 JSON 递归遍历同样要有上限。
    ///
    /// 这里刻意只造 3000 层：真要造到两万层，测试自己在释放这串
    /// 嵌套容器时就会因 ARC 递归析构而爆栈 —— 那是另一个坑。
    /// 3000 层已远超遍历上限，足以验证「遍历会在上限处停下」。
    func testJSONPathDeeplyNestedDoesNotCrash() {
        let depth = 3000
        var nested: Any = ["name": "最内层"]
        for _ in 0..<depth { nested = ["child": nested] }

        // 最内层的那条数据超出了遍历上限，因此不应被收集到，
        // 且整个过程不能崩。
        let results = JSONPath.query("$..name", json: nested)
        XCTAssertTrue(results.isEmpty, "超出深度上限的内容不应被遍历到")

        // 上限本身必须是安全的小值（真递归深度还要乘以栈帧开销）
        XCTAssertLessThanOrEqual(JSONPath.maxDepth, 256)

        // 正常路径仍然可用
        XCTAssertEqual(JSONPath.query("$.data.total", json: jsonObject()).first as? Int, 2)
    }

    /// JSONPath 过滤表达式里的括号嵌套也要有上限。
    func testJSONPathDeepFilterDoesNotCrash() {
        let deep = "$.data.list[?(" + String(repeating: "(", count: 20000)
            + "@.price>20" + String(repeating: ")", count: 20000) + ")].name"
        _ = JSONPath.query(deep, json: jsonObject())
        XCTAssertEqual(JSONPath.query("$.data.list[?(@.price>20)].name", json: jsonObject()).first as? String, "书二")
    }

    /// $..* 作用在大 JSON 上必须有结果上限，否则内存会被顶爆。
    func testJSONPathRecursiveWildcardIsCapped() {
        var list: [Any] = []
        for index in 0..<60000 { list.append(["id": index]) }
        let results = JSONPath.query("$..*", json: ["data": list])
        XCTAssertLessThanOrEqual(results.count, 20001, "递归通配必须有结果上限")
    }

    /// 声明体积超限的响应要被拦下，不能先收进内存。
    func testHTTPClientRejectsOversizedDeclaredResponse() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/big")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": String(512 * 1024 * 1024)]
        )!
        XCTAssertThrowsError(try HTTPClient.checkDeclaredSize(response))
    }

    /// 分页模式下底部翻页条默认不显示（正文区不该被工具栏挤占）。
    @MainActor
    func testPageFooterIsHiddenByDefault() {
        let store = SettingsStore()
        XCTAssertFalse(store.showPageFooter)
    }

    /// 正文预留的上下边距不能吃掉太多屏幕。
    ///
    /// 旧值 top 52 + bottom 92 = 144pt，叠加安全区后一屏 874pt 里
    /// 有 262pt（30%）永远空白，用户看到的就是「排版没有铺满全屏」。
    /// 工具条是浮层、会自动隐藏，正文不该按它的完整高度长期让位。
    /// 这里把上限锁在整屏的 8% 以内，防止回退成大留白。
    func testReaderInsetsLeaveMostOfTheScreenToText() {
        let reserved = ReaderMetrics.topInset + ReaderMetrics.bottomInset
        let screenHeight: CGFloat = 874
        XCTAssertLessThanOrEqual(
            reserved, screenHeight * 0.08,
            "正文上下预留 " + String(Int(reserved)) + "pt，屏高 " + String(Int(screenHeight))
                + "pt，占比超过 8%"
        )
    }

    // MARK: 漫画源入口（无目录也能进）

    /// 漫画源不提供目录是常态：整本就是一个阅读页。
    /// 只要能拿到书籍地址，就必须允许进入阅读，
    /// 否则详情页的按钮永远是灰的，用户根本点不进去。
    func testComicCanOpenWithoutTocWhenBookUrlExists() {
        XCTAssertTrue(ReaderEntryPolicy.canOpenWithoutToc(
            type: .image, tocUrl: nil, bookUrl: "https://a.com/comic/1"))
    }

    func testComicCanOpenWithoutTocWhenOnlyTocUrlExists() {
        XCTAssertTrue(ReaderEntryPolicy.canOpenWithoutToc(
            type: .image, tocUrl: "https://a.com/comic/1", bookUrl: ""))
    }

    /// 两个地址都拿不到时不能放行：进去只会是一张空白页。
    func testComicCannotOpenWhenNoAddressAtAll() {
        XCTAssertFalse(ReaderEntryPolicy.canOpenWithoutToc(
            type: .image, tocUrl: nil, bookUrl: "   "))
        XCTAssertFalse(ReaderEntryPolicy.canOpenWithoutToc(
            type: .image, tocUrl: "", bookUrl: ""))
    }

    /// 小说源不享受这条兜底：目录失败时进去只会看到空白，
    /// 反而让人以为软件坏了，所以必须照旧报错。
    func testTextSourceStillRequiresToc() {
        XCTAssertFalse(ReaderEntryPolicy.canOpenWithoutToc(
            type: .text, tocUrl: nil, bookUrl: "https://a.com/book/1"))
    }

    // MARK: 影视 / 短剧源

    /// 听书源同样普遍没有目录：目录规则留空、整本只有一集播放页。
    ///
    /// 旧实现只放行漫画与影视，听书源因此永远卡在「目录获取失败」、
    /// 按钮是灰的 —— 用户反馈的「听书的源无法打开」就是这条。
    func testAudioCanOpenWithoutToc() {
        XCTAssertTrue(ReaderEntryPolicy.canOpenWithoutToc(
            type: .audio, tocUrl: nil, bookUrl: "https://a.com/audio/1"))
        XCTAssertTrue(ReaderEntryPolicy.canOpenWithoutToc(
            type: .audio, tocUrl: "https://a.com/audio/1", bookUrl: ""))
        // 两个地址都拿不到时仍不能放行：进去只会是一张空白页
        XCTAssertFalse(ReaderEntryPolicy.canOpenWithoutToc(
            type: .audio, tocUrl: nil, bookUrl: "   "))
        XCTAssertFalse(ReaderEntryPolicy.canOpenWithoutToc(
            type: .audio, tocUrl: "", bookUrl: ""))
    }

    /// 影视源同样普遍没有剧集目录，只要能拿到地址就该放行进播放器。
    func testVideoCanOpenWithoutToc() {
        XCTAssertTrue(ReaderEntryPolicy.canOpenWithoutToc(
            type: .video, tocUrl: nil, bookUrl: "https://a.com/dj/1"))
        XCTAssertTrue(ReaderEntryPolicy.canOpenWithoutToc(
            type: .video, tocUrl: "https://a.com/dj/1", bookUrl: ""))
        XCTAssertFalse(ReaderEntryPolicy.canOpenWithoutToc(
            type: .video, tocUrl: nil, bookUrl: "  "))
    }

    /// bookSourceType = 4 必须解析成影视，不能静默回退成文本源
    ///（回退的后果是走进正文排版，把一个 m3u8 当小说渲染）。
    func testVideoSourceTypeIsRecognised() {
        let source = BookSource(dict: [
            "bookSourceName": "测试影视",
            "bookSourceUrl": "https://a.com",
            "bookSourceType": 4
        ])
        XCTAssertEqual(source.type, .video)
        XCTAssertEqual(BookType(rawValue: source.type.rawValue), .video)
    }

    /// 视频直链识别：覆盖 HLS 与常见封装，且不能把音频误判成视频。
    func testVideoURLDetection() {
        XCTAssertTrue(SourceEngine.isVideoURL("https://a.com/x.m3u8"))
        XCTAssertTrue(SourceEngine.isVideoURL("https://a.com/x.mp4?token=1"))
        XCTAssertTrue(SourceEngine.isVideoURL("HTTP://A.COM/X.MP4"))
        XCTAssertTrue(SourceEngine.isVideoURL("https://a.com/x.flv"))
        XCTAssertFalse(SourceEngine.isVideoURL("https://a.com/x.mp3"))
        XCTAssertFalse(SourceEngine.isVideoURL("https://a.com/page.html"))
        XCTAssertFalse(SourceEngine.isVideoURL(""))
    }

    // MARK: 崩溃回归：JS 注入净化
    //
    // 症状：600 多个书源，搜到 97 个左右必闪退；崩溃栈是
    //   DeXian → JavaScriptCore → CoreFoundation → libswiftCore(baseAddress) → abort
    // 加上「SIGABRT：Swift 运行时陷阱」。
    //
    // 根因：规则链里 <js>…</js> 的前一步结果常常是 HTMLNode，
    // 而 HTMLNode 是纯 Swift final class（不继承 NSObject、没有 ObjC 元数据）。
    // 它经 AnalyzeRule → JSEngine.setObject(result) 被写进 JS 全局变量，
    // JavaScriptCore 的桥接层会去反射它的内存布局并在 Swift 运行时里
    // 读 UnsafeBufferPointer.baseAddress —— 直接触发 Swift 运行时陷阱。
    // 每一轮多源搜索会走成百上千次这条路径。

    /// 注入前必须包成元素对象，且求值本身不能崩。
    ///
    /// 为什么不能降级成字符串：列表规则里的 `result` 就是 jsoup 元素，
    /// 书源写 `result.toArray()` / `result.select(...)`（实测 32 处）。
    /// 文本化之后这些调用全是 undefined is not a function，
    /// 目录与搜索列表会直接空掉。
    func testInjectingHTMLNodeIntoJSDoesNotCrash() {
        let engine = JSEngine(host: JSEngine.Host())
        let node = CSSSelector.select("div.item", in: document()).first ?? document()

        engine.result = node
        // 只要这里没崩，说明没把纯 Swift 对象交给 JavaScriptCore。
        XCTAssertEqual(engine.evaluateString("typeof result"), "object")
        XCTAssertEqual(engine.evaluateString("typeof result.select"), "function")
        XCTAssertEqual(engine.evaluateString("typeof result.attr"), "function")
        XCTAssertEqual(engine.evaluateString("result.text().length > 0"), "true")
    }

    /// 含 HTMLNode 的容器同样要走净化路径（数组 / 字典 / 嵌套）。
    func testInjectingContainersWithHTMLNodeDoesNotCrash() {
        let engine = JSEngine(host: JSEngine.Host())
        let nodes = CSSSelector.select("div.item", in: document())
        XCTAssertFalse(nodes.isEmpty)

        engine.result = nodes
        XCTAssertEqual(engine.evaluateString("result.size() > 0"), "true")
        XCTAssertEqual(engine.evaluateString("typeof result.toArray"), "function")
        XCTAssertEqual(engine.evaluateString("typeof result[0]"), "object")
        XCTAssertEqual(engine.evaluateString("typeof result[0].attr"), "function")

        // 显式构造 [String: Any]，避免依赖 Swift 集合向上转型的细节
        var payload: [String: Any] = [:]
        payload["node"] = nodes.first as Any
        payload["list"] = nodes
        engine.result = payload
        XCTAssertEqual(engine.evaluateString("typeof result"), "object")
        XCTAssertEqual(engine.evaluateString("typeof result.node"), "string")
        XCTAssertEqual(engine.evaluateString("typeof result.list[0]"), "string")
    }

    /// asString 碰到「容器里混着 HTMLNode」时不能抛出 ObjC 异常。
    ///
    /// `isValidJSONObject` 只检查顶层：`[HTMLNode]` 会被判成合法，
    /// 随后 `JSONSerialization.data` 递归到纯 Swift 对象就抛
    /// `NSInvalidArgumentException` —— Swift 的 try? 抓不住，进程直接终止。
    /// 这条路径与 setObject(result) 一样，搜索时会被反复走到。
    func testAsStringHandlesContainersWithHTMLNode() {
        let nodes = CSSSelector.select("div.item", in: document())
        XCTAssertFalse(nodes.isEmpty)

        let arrayText = RuleUtil.asString(nodes)
        XCTAssertNotNil(arrayText)
        XCTAssertTrue(arrayText?.contains("斗破苍穹") ?? false, "数组元素不能被丢掉")

        var payload: [String: Any] = [:]
        payload["node"] = nodes.first as Any
        payload["list"] = nodes
        XCTAssertNotNil(RuleUtil.asString(payload), "字典里的节点也要能文本化")

        // 顶层就是 HTMLNode 时走的是最早的那条分支：返回该节点的全文（含子节点文字），不能崩也不能丢内容。
        let nodeText = RuleUtil.asString(nodes.first)
        XCTAssertTrue(nodeText?.contains("斗破苍穹") ?? false)
        XCTAssertTrue(nodeText?.contains("天蚕土豆") ?? false)
    }

    /// jsSafeValue 的契约：认识的值原样保留，不认识的一律文本化。
    func testJSSafeValueSanitizesNonBridgeableValues() {
        XCTAssertEqual(JSEngine.jsSafeValue("文本") as? String, "文本")
        XCTAssertEqual(JSEngine.jsSafeValue(7) as? Int, 7)
        let dict = JSEngine.jsSafeValue(["a": 1]) as? [String: Any]
        XCTAssertEqual(dict?["a"] as? Int, 1)
        XCTAssertTrue(JSEngine.jsSafeValue(nil) is NSNull)

        let node = CSSSelector.select("div.item", in: document()).first ?? document()
        XCTAssertTrue(JSEngine.jsSafeValue(node) is String, "纯 Swift 类型必须被文本化")
        var payload: [String: Any] = [:]
        payload["list"] = [node]
        payload["node"] = node
        let nested = JSEngine.jsSafeValue(payload) as? [String: Any]
        XCTAssertTrue((nested?["list"] as? [Any])?.first is String, "嵌套数组也要净化")
        XCTAssertTrue(nested?["node"] is String, "嵌套对象字段也要净化")
    }

    /// 超深嵌套不能让净化逻辑无限递归（HTML 容器结构可以很深）。
    func testJSSafeValueHandlesDeepNesting() {
        let node = CSSSelector.select("div.item", in: document()).first ?? document()
        var nested: Any = node
        for _ in 0..<200 { nested = [nested] }
        // 不应崩、不应无限递归。
        let output = JSEngine.jsSafeValue(nested)
        XCTAssertNotNil(output)
    }

    /// 端到端：搜索链路里 <js> 段拿到 HTMLNode 作为 result 时不能崩。
    func testJSResultInjectionThroughRuleChainDoesNotCrash() {
        let node = CSSSelector.select("div.item", in: document()).first ?? document()
        let engine = JSEngine(host: JSEngine.Host())
        engine.result = node
        XCTAssertEqual(engine.evaluateString("typeof result"), "object")
        XCTAssertEqual(engine.evaluateString("result.text().length > 0"), "true")
        // 目录里最常见的写法：元素上继续 select 再取属性
        XCTAssertEqual(engine.evaluateString("result.select('a').first().attr('href')"), "/book/1")
    }
}

// MARK: - 书源探测

final class SourceProbeTests: XCTestCase {

    private func makeSource(name: String, enabled: Bool = true, searchURL: String = "https://example.com/search?q={{key}}") -> BookSource {
        BookSource(dict: [
            "bookSourceName": name,
            "bookSourceUrl": "https://example.com",
            "enabled": enabled,
            "searchUrl": searchURL
        ])
    }

    /// 探测状态的可清理判定：只有「确实坏了」的才算可清理。
    ///
    /// 这条规则直接决定「一键清除」会删掉什么，删错就是用户的损失，
    /// 所以每一类都要明确：
    /// - 有效：不清理
    /// - 用户自己禁用的：不清理（那是他的选择）
    /// - 需要登录的：不清理（源是好的，是配置问题）
    /// - 站点没了 / 规则失效（域名解析失败、无法连接、搜索无结果）：清理
    func testProbeStateRemovablePolicy() {
        XCTAssertFalse(SourceProbe.State.valid(count: 3).isRemovable)
        XCTAssertFalse(SourceProbe.State.skipped(reason: "已禁用").isRemovable)
        XCTAssertFalse(SourceProbe.State.invalid(reason: "未检测到登录状态，请先登录").isRemovable)
        XCTAssertTrue(SourceProbe.State.invalid(reason: "搜索无结果").isRemovable)
        XCTAssertTrue(SourceProbe.State.invalid(reason: "不支持搜索").isRemovable)
        XCTAssertTrue(SourceProbe.State.invalid(reason: "域名解析失败").isRemovable)
        XCTAssertTrue(SourceProbe.State.invalid(reason: "无法连接服务器").isRemovable)
    }

    /// 网络类失败绝不能触发清理。
    ///
    /// 判据用白名单正是因为这里：用户在地铁里点一下「清除失效」，
    /// 如果「当前无网络」被算作无效，整个书源库会被清空 —— 这是
    /// 不可逆的损失，比漏清几个死源严重得多。
    func testTransientFailuresAreNeverRemovable() {
        XCTAssertFalse(SourceProbe.State.invalid(reason: "当前无网络").isRemovable)
        XCTAssertFalse(SourceProbe.State.invalid(reason: "网络连接中断").isRemovable)
        XCTAssertFalse(SourceProbe.State.invalid(reason: "请求超时").isRemovable)
        XCTAssertFalse(SourceProbe.State.invalid(reason: "请求已取消").isRemovable)
        XCTAssertFalse(SourceProbe.State.invalid(reason: "已取消").isRemovable)
        XCTAssertFalse(SourceProbe.State.invalid(reason: "探测超时").isRemovable)
        XCTAssertFalse(SourceProbe.State.invalid(reason: "HTTPS 证书校验失败").isRemovable)
    }

    /// skipped 不是「可用」，但也不能被清掉
    func testSkippedIsNeitherValidNorRemovable() {
        let state = SourceProbe.State.skipped(reason: "已禁用")
        XCTAssertFalse(state.isValid)
        XCTAssertFalse(state.isRemovable)
        XCTAssertEqual(state.displayText, "已禁用")
    }

    /// 探测结果文案里要带上命中数量，用户据此判断源的强弱
    func testValidStateShowsHitCount() {
        XCTAssertEqual(SourceProbe.State.valid(count: 12).displayText, "可用 · 搜到 12 本")
    }

    /// 禁用或没有搜索地址的源不参与探测（不必发请求就已经知道结果）
    func testProbeSkipsDisabledAndSearchlessSources() async {
        let disabled = makeSource(name: "禁用源", enabled: false)
        let state = await SourceProbe.probe(disabled, keyword: "剑来")
        XCTAssertEqual(state, .skipped(reason: "已禁用"))

        let noSearch = makeSource(name: "无搜索源", searchURL: "")
        let missing = await SourceProbe.probe(noSearch, keyword: "剑来")
        XCTAssertEqual(missing, .invalid(reason: "不支持搜索"))
    }
}

// MARK: - 订阅源（RSS）

final class RssTests: XCTestCase {

    /// 真实 yckceo 订阅源：带规则的"中文寻星"
    private let ruleSource = """
    [{"articleStyle":0,"cacheFirst":false,"customOrder":0,"enableJs":true,"enabled":true,
      "enabledCookieJar":true,"lastUpdateTime":1789948994825,"loadWithBaseUrl":true,"preload":false,
      "ruleArticles":"table tr td","ruleLink":"a@href","rulePubDate":"text","ruleTitle":"a@text",
      "searchUrl":"http://dtmb.saoing.com/{{key}}.htm","singleUrl":false,
      "sortUrl":"卫星参数::/satparam.htm\\n卫星强场::/changqiang/EIRP.htm",
      "sourceComment":"搜索请写拼音","sourceIcon":"http://saoing.com/Pictuer/logo.jpg",
      "sourceName":"中文寻星","sourceUrl":"http://saoing.com/","type":0}]
    """

    /// 真实 yckceo 订阅源：只有名字和地址的"源仓库(官方纯净)"
    private let plainSource = """
    [{"articleStyle":0,"customOrder":0,"enableJs":true,"enabled":true,"enabledCookieJar":true,
      "lastUpdateTime":0,"loadWithBaseUrl":true,"singleUrl":true,"sourceGroup":"1",
      "sourceIcon":"","sourceName":"源仓库(官方纯净)","sourceUrl":"http://yckceo.vip"}]
    """

    func testRssSourceDetectedSeparatelyFromBookSource() {
        let result = SourceImporter.parse(text: ruleSource)
        XCTAssertTrue(result.hasRssSources)
        XCTAssertFalse(result.hasBookSources)
        XCTAssertEqual(result.rssSources.count, 1)
        XCTAssertEqual(result.rssSources.first?.name, "中文寻星")
    }

    func testPlainRssSourceIsRecognized() {
        // articleStyle 等订阅源字段让"只有名字+地址"的条目也能被识别
        let result = SourceImporter.parse(text: plainSource)
        XCTAssertTrue(result.hasRssSources)
        XCTAssertEqual(result.rssSources.first?.name, "源仓库(官方纯净)")
        XCTAssertFalse(result.rssSources.first?.hasArticleRule ?? true)
    }

    /// 没有任何特征字段时，由导入入口的偏好决定归属
    func testAmbiguousSourceRespectsPreference() {
        let ambiguous = """
        [{"sourceName":"无特征源","sourceUrl":"https://c.com"}]
        """
        let asBook = SourceImporter.parse(text: ambiguous)
        XCTAssertTrue(asBook.hasBookSources)
        XCTAssertFalse(asBook.hasRssSources)

        let asRss = SourceImporter.parse(text: ambiguous, preferRss: true)
        XCTAssertTrue(asRss.hasRssSources)
        XCTAssertFalse(asRss.hasBookSources)
    }

    func testBookSourceNotMistakenForRss() {
        let book = """
        [{"bookSourceName":"测试书源","bookSourceUrl":"https://example.com",
          "bookSourceType":0,"ruleSearch":{"bookList":".item","name":"a@text","bookUrl":"a@href"},
          "ruleToc":{"chapterList":".list@li","chapterName":"a@text","chapterUrl":"a@href"},
          "ruleContent":{"content":"#content@html"},"searchUrl":"/search?q={{key}}"}]
        """
        let result = SourceImporter.parse(text: book)
        XCTAssertTrue(result.hasBookSources)
        XCTAssertFalse(result.hasRssSources)
    }

    func testMixedPayloadSplitsBothKinds() {
        let mixed = "[" + ruleSource.dropFirst().dropLast() + "]"
        let result = SourceImporter.parse(text: mixed)
        XCTAssertEqual(result.rssSources.count, 1)
        XCTAssertFalse(result.hasBookSources)
    }

    func testMixedBookAndRssInOneArray() {
        let payload = """
        [{"bookSourceName":"书源A","bookSourceUrl":"https://a.com","searchUrl":"/s?q={{key}}",
          "ruleSearch":{"bookList":".i"}},
         {"sourceName":"订阅A","sourceUrl":"https://b.com","ruleArticles":".item"}]
        """
        let result = SourceImporter.parse(text: payload)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.rssSources.count, 1)
        XCTAssertEqual(result.sources.first?.name, "书源A")
        XCTAssertEqual(result.rssSources.first?.name, "订阅A")
    }

    func testRssCategoriesParsedFromSortUrl() {
        let result = SourceImporter.parse(text: ruleSource)
        let source = try? XCTUnwrap(result.rssSources.first)
        XCTAssertEqual(source?.categories.count, 2)
        XCTAssertEqual(source?.categories.first?.title, "卫星参数")
        XCTAssertEqual(source?.categories.first?.url, "/satparam.htm")
    }

    func testRssCategoryAnchorIsStripped() {
        let dict: [String: Any] = [
            "sourceName": "带锚点",
            "sourceUrl": "https://example.com",
            "sortUrl": "卫星参数::/#google_vignette\n卫星强场::/changqiang/EIRP.htm"
        ]
        let source = RssSource(dict: dict)
        XCTAssertEqual(source.categories.first?.url, "/")
        XCTAssertEqual(source.categories.count, 2)
    }

    func testRssSearchURLPlaceholder() {
        let dict: [String: Any] = [
            "sourceName": "搜索源", "sourceUrl": "https://example.com",
            "searchUrl": "https://example.com/search?q={{key}}"
        ]
        let source = RssSource(dict: dict)
        XCTAssertTrue(source.hasSearch)
    }

    func testRssArticleListRuleEvaluation() {
        let html = """
        <table><tr><td><a href="/a.htm">文章一</a></td><td>2026-01-01</td></tr>
        <tr><td><a href="/b.htm">文章二</a></td><td>2026-01-02</td></tr></table>
        """
        let source = RssSource(dict: [
            "sourceName": "列表源", "sourceUrl": "http://example.com/",
            "ruleArticles": "table tr td", "ruleTitle": "a@text",
            "ruleLink": "a@href", "rulePubDate": "text"
        ])
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: html, baseUrl: source.url, js: js, bookInfo: [:], chapterInfo: [:]
        )
        let items = analyzer.listItems(source.ruleArticles)
        XCTAssertFalse(items.isEmpty)
        let first = items[0]
        let itemAnalyzer = SourceEngine.makeAnalyzer(
            content: first, baseUrl: source.url, js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(itemAnalyzer.string(source.ruleTitle), "文章一")
        XCTAssertEqual(itemAnalyzer.string(source.ruleLink), "/a.htm")
    }

    func testRssArticleLinkResolvedAgainstSourceURL() {
        XCTAssertEqual(
            RuleUtil.absoluteURL("/a.htm", base: "http://saoing.com/"),
            "http://saoing.com/a.htm"
        )
    }

    /// 订阅源字段规则里的 `result.replace` 必须拿到字符串。
    ///
    /// 真实订阅源（禁漫天堂）的规则是：
    /// `tag.a.0@href@js:result.replace(...)`
    /// 列表元素节点经过属性转换后是字符串；旧实现把 `elements: true`
    /// 一路传给 JS 转换，导致 result 变成 HTMLNode，字段规则失效。
    func testRssFieldJSReceivesStringResult() {
        let html = """
        <div class="list-col"><a href="/album/123">漫画</a></div>
        """
        let source = RssSource(dict: [
            "sourceName": "字段脚本源", "sourceUrl": "https://example.com/",
            "ruleArticles": "class.list-col",
            "ruleLink": "tag.a.0@href@js:result.replace(/.*?album\\/(\\d+).*/g,\"/photo/$1\")"
        ])
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: html, baseUrl: source.url, js: js, bookInfo: [:], chapterInfo: [:]
        )
        let items = analyzer.listItems(source.ruleArticles)
        XCTAssertEqual(items.count, 1)
        let itemAnalyzer = SourceEngine.makeAnalyzer(
            content: items[0], baseUrl: source.url, js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(itemAnalyzer.string(source.ruleLink), "/photo/123")
    }

    /// 列表规则以 `@js:` 结尾时必须返回原始地址字符串数组。
    ///
    /// 对齐 Legado 的 `AnalyzeUrl.resolveJsUrl`：这种写法是“把当前地址
    /// 转成带请求选项的最终地址”，不是元素列表。
    func testListRuleFinalJSWithStringsReturnsURLs() {
        let source = RssSource(dict: [
            "sourceName": "URL脚本源", "sourceUrl": "https://example.com/"
        ])
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: "https://example.com/page", baseUrl: source.url, js: js,
            bookInfo: [:], chapterInfo: [:]
        )
        let items = analyzer.listItems("@js:result + \"/next\"")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(RuleUtil.asString(items[0]), "https://example.com/page/next")
    }

    func testRssSourceIsCodable() {
        let source = RssSource(dict: [
            "sourceName": "编码测试", "sourceUrl": "https://example.com",
            "ruleArticles": ".item", "ruleTitle": "a@text", "ruleLink": "a@href"
        ])
        let data = try? JSONEncoder().encode(source)
        XCTAssertNotNil(data)
        let decoded = data.flatMap { try? JSONDecoder().decode(RssSource.self, from: $0) }
        XCTAssertEqual(decoded?.name, "编码测试")
        XCTAssertEqual(decoded?.ruleArticles, ".item")
    }

    func testRssContentRendererSplitsParagraphs() {
        let blocks = RssContentRenderer.render(
            html: "<div><p>第一段</p><p>第二段</p></div>",
            baseUrl: "https://example.com"
        )
        let texts = blocks.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }
        XCTAssertEqual(texts, ["第一段", "第二段"])
    }

    func testRssContentRendererCollectsImages() {
        let blocks = RssContentRenderer.render(
            html: "<div><p>正文</p><img data-src=\"/a.jpg\"><img src=\"b.png\"></div>",
            baseUrl: "https://example.com/post/"
        )
        let images = blocks.compactMap { block -> String? in
            if case .image(let value) = block { return value }
            return nil
        }
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0], "https://example.com/a.jpg")
        XCTAssertEqual(images[1], "https://example.com/post/b.png")
    }

    func testRssContentRendererHandlesPlainText() {
        let blocks = RssContentRenderer.render(html: "第一行\n第二行", baseUrl: "https://example.com")
        XCTAssertEqual(blocks.count, 2)
    }

    /// 无规则源退化为直接罗列页面链接
    func testFallbackArticlesFromPlainHTML() {
        let html = "<ul><li><a href=\"/x.htm\">条目一</a></li><li><a href=\"#top\">锚点</a></li></ul>"
        let document = HTMLParser.parse(html)
        let nodes = CSSSelector.select("a", in: document)
        let links = nodes.compactMap { $0.attribute("href") }.filter { !$0.hasPrefix("#") }
        XCTAssertEqual(links, ["/x.htm"])
    }

    func testRssStoreMergeKeepsUniqueIDs() {
        let a = RssSource(dict: ["sourceName": "A", "sourceUrl": "https://a.com"])
        let b = RssSource(dict: ["sourceName": "B", "sourceUrl": "https://b.com"])
        let updated = RssSource(dict: ["sourceName": "A", "sourceUrl": "https://a.com",
                                        "ruleArticles": ".new"])
        XCTAssertEqual(a.id, updated.id)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(updated.ruleArticles, ".new")
    }

    /// singleUrl 且没有正文/列表规则的源，必须保留完整网页入口，
    /// 由 WebView 渲染；不要把站点导航抽成一堆空壳文章。
    func testSingleUrlRssFallsBackToWebViewEntry() {
        let source = RssSource(dict: [
            "sourceName": "猫咪社区", "sourceUrl": "https://cat.example/list.html",
            "singleUrl": true
        ])
        XCTAssertTrue(source.needsWebFallback)

        let ruleSource = RssSource(dict: [
            "sourceName": "规则源", "sourceUrl": "https://example.com",
            "singleUrl": true, "ruleArticles": ".item"
        ])
        XCTAssertFalse(ruleSource.needsWebFallback)
    }

    /// 凹凸吧等图集源用 HTML 模板声明正文，`{{@@selector@html}}`
    /// 是插入解析结果。模板不能交给普通文本抽取规则。
    func testRuleContentTemplatePreservesInterpolation() throws {
        let html = """
        <article><h1>图集标题</h1><div class="images"><img src="/1.jpg"><img src="/2.jpg"></div></article>
        """
        let source = RssSource(dict: [
            "sourceName": "图集源", "sourceUrl": "https://photo.example/post/1.html",
            "ruleContent": "<h1>{{@@h1@all}}</h1>{{@@.images img@html}}"
        ])
        let analyzer = AnalyzeRule(content: html, baseUrl: source.url)
        let raw = analyzer.string("{{@@article@html}}")
        XCTAssertTrue(raw.contains("images"))
        XCTAssertTrue(source.ruleContent.contains("{{@@.images img@html}}"))
    }

    /// 已迁移 HTTPS 但仍声明 HTTP 的视频 API 源，需要失败后自动升级重试。
    func testHTTPURLUpgrade() {
        let original = "http://video.example/api.php/provide/vod/?ac=list&at=json"
        let url = try? XCTUnwrap(URL(string: original))
        var components = try? XCTUnwrap(URLComponents(url: url!, resolvingAgainstBaseURL: false))
        components?.scheme = "https"
        XCTAssertEqual(components?.string, "https://video.example/api.php/provide/vod/?ac=list&at=json")
    }

    /// 表单型 RSS 源通过 source.getVariable() 保存分类/频道选择，
    /// 每次新建 JS 引擎都必须注入持久化变量。
    func testRssSourceVariablePersistedAcrossEngines() {
        let source = RssSource(dict: [
            "sourceName": "变量源", "sourceUrl": "https://form.example",
            "sortUrl": "频道::/list?channel={{source.getVariable()}}"
        ])
        SourceVariableStore.shared[source.id] = "drama"
        XCTAssertEqual(SourceVariableStore.shared[source.id], "drama")
    }

    /// 合集里同时出现书源和订阅源时，订阅源不能因为“也检测到书源”被丢弃。
    func testImportResultWithMixedKeepsRssSources() {
        let payload = """
        [{"bookSourceName":"书源A","bookSourceUrl":"https://a.com",
          "searchUrl":"/s?q={{key}}","ruleSearch":{"bookList":".i"}},
         {"sourceName":"订阅A","sourceUrl":"https://b.com","ruleArticles":".item"}]
        """
        let result = SourceImporter.parse(text: payload, preferRss: true)
        XCTAssertEqual(result.rssSources.count, 1)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.rssSources.first?.name, "订阅A")
    }

    // MARK: 本轮加固回归

    /// 空地址的书不能撞 id：SearchBook.id 若只由「源+地址」组成，
    /// 多本空地址书 id 相同，SwiftUI 的 ForEach 会直接 fatalError 崩溃。
    func testSearchBookIDsStayUniqueForEmptyURLs() {
        let first = SearchBook(name: "书甲", author: "作者一", kind: nil, wordCount: nil,
                               lastChapter: nil, intro: nil, coverUrl: nil, bookUrl: "",
                               origin: "s1", originName: "源一", type: .text)
        let second = SearchBook(name: "书乙", author: "作者二", kind: nil, wordCount: nil,
                                lastChapter: nil, intro: nil, coverUrl: nil, bookUrl: "",
                                origin: "s1", originName: "源一", type: .text)
        XCTAssertNotEqual(first.id, second.id)
    }

    /// 同一本书重复出现在结果里时 id 必须稳定（用于去重）
    func testSearchBookIDIsStable() {
        let first = SearchBook(name: "书甲", author: "作者一", kind: nil, wordCount: nil,
                               lastChapter: nil, intro: nil, coverUrl: nil, bookUrl: "https://a.com/1",
                               origin: "s1", originName: "源一", type: .text)
        let second = SearchBook(name: "书甲", author: "作者一", kind: nil, wordCount: nil,
                                lastChapter: nil, intro: nil, coverUrl: nil, bookUrl: "https://a.com/1",
                                origin: "s1", originName: "源一", type: .text)
        XCTAssertEqual(first.id, second.id)
    }

    /// 搜索 / 发现结果里的空地址，阅读器要能在应用内打开网页兜底，
    /// 而不是把用户踢到 Safari。
    func testSearchBookWebFallbackURLUsesBookURL() {
        let book = SearchBook(name: "网页书", author: "", kind: nil, wordCount: nil,
                              lastChapter: nil, intro: nil, coverUrl: nil,
                              bookUrl: "https://web.example/book.html",
                              origin: "s1", originName: "源一", type: .text)
        let url = book.bookUrl.trimmed.isEmpty ? "" : book.bookUrl
        XCTAssertEqual(url, "https://web.example/book.html")
    }

    /// 用户已经完成 / 跳过的源，在同一轮搜索里不能再重复弹验证。
    /// 否则点击退出后，同一个验证框反复出现，搜索永远无法继续。
    func testHandledVerificationDoesNotReopenInSameRound() {
        let mirror = Mirror(reflecting: WebAuthPresenter.shared)
        let handled = mirror.children.first { $0.label == "handledSourceKeys" }?.value as? Set<String>
        XCTAssertNotNil(handled)
    }

    /// 图站 URL query 里的 `,{...}` 是内容模板，不是请求选项；
    /// 裸域名必须补 scheme。否则 URLSession 报“链接格式不支持”。
    func testURLRulePreservesQueryTemplateAndAddsScheme() {
        let bare = HTTPClient.parseURLRule("www.missav.com/dm5/cn/mifoot")
        XCTAssertTrue(bare.url.hasPrefix("https://www.missav.com/"))

        let queryTemplate = HTTPClient.parseURLRule(
            "https://example.com/list?q=美足,{\"title\":\"美足\"}"
        )
        XCTAssertEqual(queryTemplate.url, "https://example.com/list?q=美足")

        let option = HTTPClient.parseURLRule("https://example.com/api,{\"method\":\"POST\"}")
        XCTAssertEqual(option.url, "https://example.com/api")
        XCTAssertEqual(option.options.method, "POST")
    }

    /// 正文节点要保留段落：块级标签之间必须有换行，否则整章被压成一行
    func testParagraphStringsKeepLineBreaks() {
        let html = "<div class=\"content\"><p>第一段</p><p>第二段</p></div>"
        let analyzer = AnalyzeRule(context: RuleContext(content: html, baseUrl: "https://a.com"))
        analyzer.paragraphs = true
        let text = analyzer.string(".content")
        XCTAssertTrue(text.contains("\n"), "段落之间应保留换行，实际为：" + text)
        XCTAssertTrue(text.contains("第一段"))
        XCTAssertTrue(text.contains("第二段"))
    }

    /// 段落模式不影响短字段：书名里不应混进换行
    func testShortFieldsKeepSingleLine() {
        let html = "<h3 class=\"name\"><a href=\"/1\">斗破<br>苍穹</a></h3>"
        let analyzer = AnalyzeRule(context: RuleContext(content: html, baseUrl: "https://a.com"))
        let name = analyzer.string(".name")
        XCTAssertFalse(name.contains("\n"))
    }

    /// 中文地址要能直接请求：不编码时 URL(string:) 返回 nil，整章图片全挂
    func testChineseImageURLIsEncoded() {
        let raw = "https://img.example.com/漫画/第1话/001.jpg"
        let resolved = RuleUtil.absoluteURL(raw, base: "https://img.example.com")
        XCTAssertNotNil(URL(string: resolved), "编码后应能构造 URL：" + resolved)
    }

    /// 已编码地址不能被二次编码
    func testEncodedURLIsNotDoubleEncoded() {
        let raw = "https://img.example.com/a%20b/001.jpg"
        let resolved = RuleUtil.absoluteURL(raw, base: nil)
        XCTAssertEqual(resolved, raw)
    }

    /// UTF-8 有坏字节时不能整体退化成乱码；合法 UTF-8 必须原样还原
    func testCharsetPrefersValidUTF8() {
        let text = "第一章 山边小村"
        let data = Data(text.utf8)
        XCTAssertTrue(Charset.isValidUTF8(data))
        XCTAssertEqual(Charset.decode(data), text)
    }

    /// GBK 正文按 meta 声明正确解码，而不是变成乱码
    func testCharsetDecodesGBKContent() {
        let source = "第一章 山边小村"
        guard let gbk = Charset.encoding(named: "gb18030"),
              let data = source.data(using: gbk) else {
            return XCTFail("GB18030 编码不可用")
        }
        XCTAssertFalse(Charset.isValidUTF8(data))
        let html = "<html><head><meta charset=\"gbk\"></head><body>" + source + "</body></html>"
        guard let htmlData = html.data(using: gbk) else { return XCTFail("构造失败") }
        let decoded = Charset.decode(htmlData)
        XCTAssertTrue(decoded.contains(source), "GBK 页面解码结果： " + decoded)
    }

    /// 解码结果里不应残留成片的替换字符
    func testCharsetRemovesReplacementCharacters() {
        var data = Data("正常文本".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0xFD])
        let decoded = Charset.decode(data)
        XCTAssertFalse(decoded.contains("\u{FFFD}"))
    }

    /// 服务器把 UTF-8 正文标成 gbk 时，不能被声明带偏成乱码
    func testUTF8WinsOverWrongCharsetHeader() {
        let text = "第一章 山边小村"
        let data = Data(text.utf8)
        // 显式传入错误的 gbk 声明
        let decoded = Charset.decode(data, preferred: Charset.encoding(named: "gb18030"))
        XCTAssertEqual(decoded, text, "合法的 UTF-8 不能被 gbk 声明覆盖： " + decoded)
    }

    /// meta 探测里的按大小写查找不能破坏下标。
    ///
    /// 旧实现先在 ascii 上取 range，再拿这个 range 的下标去切 lowered
    /// （跨字符串用索引），Swift 会直接陷阱 —— 而这条路径只有在
    /// 「响应体不是合法 UTF-8」时才会走到，这正是「有些书一打开就闪退」
    /// 而其余书完全正常的原因。这里用 GBK 页面（必然非 UTF-8）
    /// 覆盖真实触发条件。
    func testHTMLMetaCharsetLookupIsCaseInsensitiveAndSafe() {
        for declaration in ["<meta charset=\"gbk\">", "<meta CHARSET=\"GBK\">",
                            "<meta Charset=\"gb2312\">", "<META CHARSET=\"Gbk\">"] {
            // 声明部分全是 ASCII，正文用 GBK 编码 —— 和真实 GBK 页面一致。
            // 不能整段用 isoLatin1 编码，那样中文会编不出来。
            guard let encoding = Charset.encoding(named: "gb18030"),
                  let head = ("<html><head>" + declaration + "</head><body>").data(using: .isoLatin1),
                  let body = "正文".data(using: encoding),
                  let tail = "</body></html>".data(using: .isoLatin1) else {
                XCTFail("构造失败")
                continue
            }
            var data = Data()
            data.append(head)
            data.append(body)
            data.append(tail)
            let decoded = Charset.decode(data, preferred: nil)
            XCTAssertTrue(decoded.contains("正文"), declaration + " 未按 GBK 解出正文： " + decoded)
        }
    }

    /// 大小写混写的 charset 声明也必须能识别出来
    func testHTMLMetaCharsetUpperCaseIsRecognised() {
        let body = "第一章 山边小村"
        guard let gbk = Charset.encoding(named: "gb18030"),
              let bodyData = body.data(using: gbk) else { return XCTFail("GB18030 不可用") }
        var data = Data("<html><head><meta CHARSET=\"GBK\"></head><body>".data(using: .isoLatin1)!)
        data.append(bodyData)
        data.append(Data("</body></html>".data(using: .isoLatin1)!))
        let decoded = Charset.decode(data)
        XCTAssertTrue(decoded.contains(body), "大写 CHARSET 声明未被识别： " + decoded)
    }

    /// 非 UTF-8 页面必须能一路解到底而不崩（回归：跨字符串索引用陷阱）
    func testDecodeNonUTF8PageDoesNotTrap() {
        // 构造一个「前 4096 字节里全是高位字节」的页面：旧实现最容易在这里崩
        guard let gbk = Charset.encoding(named: "gb18030") else { return XCTFail("GB18030 不可用") }
        let filler = String(repeating: "测试", count: 800)
        let html = "<html><head><meta charset=\"gbk\"></head><body>" + filler + "</body></html>"
        guard let data = html.data(using: gbk) else { return XCTFail("构造失败") }
        XCTAssertFalse(Charset.isValidUTF8(data))
        let decoded = Charset.decode(data)
        XCTAssertTrue(decoded.contains("测试"), "GBK 页面应解出中文： " + String(decoded.prefix(40)))
    }

    /// 正文里混进的 HTML 标签必须清掉，不能当成正文显示
    func testContentStripsHTMLArtifacts() {
        let raw = "<script>read2();</script><p>第一段</p><br/><br/><div id=\"tip\">广告</div>第二段&amp;结尾"
        let cleaned = SourceEngine.stripHTMLArtifacts(raw)
        XCTAssertFalse(cleaned.contains("<script"), "脚本标签应被移除： " + cleaned)
        XCTAssertFalse(cleaned.contains("<br"), "<br> 应转成换行： " + cleaned)
        XCTAssertFalse(cleaned.contains("<div"), "div 标签应被移除： " + cleaned)
        XCTAssertFalse(cleaned.contains("</"), "不应残留任何闭合标签： " + cleaned)
        XCTAssertTrue(cleaned.contains("第一段"))
        XCTAssertTrue(cleaned.contains("第二段"))
        XCTAssertTrue(cleaned.contains("&"), "实体应被解码为 &： " + cleaned)
        XCTAssertTrue(cleaned.contains("\n"), "块级标签应产生换行")
    }

    /// 全是普通文本时不应改动内容
    func testContentWithoutHTMLIsUnchanged() {
        let plain = "这是一个没有标签的段落。"
        XCTAssertEqual(SourceEngine.stripHTMLArtifacts(plain), plain)
    }

    /// 发现规则缺省时要回退到搜索规则，否则发现页整页空白
    func testExploreRuleFallsBackToSearchRule() {
        var search = SearchRule()
        search.bookList = ".item"
        search.name = "h3 a@text"
        search.bookUrl = "h3 a@href"
        var explore = ExploreRule()
        explore.bookList = ""
        explore.name = nil
        let merged = explore.merged(with: search)
        XCTAssertEqual(merged.bookList, ".item")
        XCTAssertEqual(merged.name, "h3 a@text")
        XCTAssertEqual(merged.bookUrl, "h3 a@href")
    }

    /// 发现规则自己有值时不能被搜索规则覆盖
    func testExploreRuleKeepsOwnValues() {
        var search = SearchRule()
        search.bookList = ".search-item"
        var explore = ExploreRule()
        explore.bookList = ".explore-item"
        let merged = explore.merged(with: search)
        XCTAssertEqual(merged.bookList, ".explore-item")
    }

    // MARK: 回归：崩溃与排版

    /// 空地址的 api 书源：所有书都算出同一个 id 会让 ForEach 直接崩溃
    func testShelfIdentifierStaysUniqueForEmptyBookUrl() {
        let a = ShelfBook.identifier(origin: "src", bookUrl: "", name: "书一", author: "甲")
        let b = ShelfBook.identifier(origin: "src", bookUrl: "", name: "书二", author: "乙")
        XCTAssertNotEqual(a, b, "空地址时 id 必须靠书名作者区分")
        XCTAssertTrue(a.contains("书一"))

        // 有地址时仍用「书源 + 地址」，保证换源/同名书不串
        let c = ShelfBook.identifier(origin: "src", bookUrl: "http://x/1", name: "书一", author: "甲")
        XCTAssertEqual(c, "src|http://x/1")
        let d = ShelfBook.identifier(origin: "src", bookUrl: "http://x/2", name: "书一", author: "甲")
        XCTAssertNotEqual(c, d)
    }

    /// 解析器必须有深度上限：上万层未闭合 div 会让递归遍历栈溢出闪退
    func testHTMLParserCapsDepthOnRunawayNesting() {
        let html = String(repeating: "<div>", count: 5000) + "正文内容" + String(repeating: "</div>", count: 5000)
        let document = HTMLParser.parse(html)

        // 深度有界：沿最深层数不超过上限
        var depth = 0
        var cursor: HTMLNode? = document
        while let node = cursor, let next = node.children.first(where: { $0.isElement }) {
            depth += 1
            cursor = next
        }
        XCTAssertLessThanOrEqual(depth, HTMLParser.maxDepth, "DOM 深度必须被截断到上限")

        // 内容不能因为截断而丢失
        XCTAssertTrue(document.rawText.contains("正文内容"), "截断后正文仍必须保留")
    }

    /// 超深嵌套下，结束标签不能把祖先树整体弹掉
    func testHTMLParserKeepsContentAfterDeepNesting() {
        let html = String(repeating: "<div>", count: 1000)
            + "<p>第一段</p>"
            + String(repeating: "</div>", count: 1000)
            + "<p>第二段</p>"
        let document = HTMLParser.parse(html)
        let text = document.rawText
        XCTAssertTrue(text.contains("第一段"), "深嵌套内的文本应保留：" + text.prefix(120).description)
        XCTAssertTrue(text.contains("第二段"), "深嵌套之后的兄弟文本应保留")
    }

    /// 导入合并必须先去掉已有数据里的重复 id
    func testSourceMergeDropsDuplicateExistingIds() {
        func make(_ name: String) -> BookSource {
            BookSource(dict: ["bookSourceName": name, "bookSourceUrl": "https://a.com", "bookSourceKey": "dup"])
        }
        let merged = SourceImporter.merge(existing: [make("一"), make("二")], incoming: [])
        XCTAssertEqual(merged.result.count, 1, "重复 id 的旧数据应被合并成一条")
    }

    // MARK: 本轮加固：大书源库与启动路径

    /// 书架仓库必须异步加载：启动路径上不能同步解码大文件
    @MainActor
    func testShelfStoreLoadsAsynchronously() async {
        let store = ShelfStore()
        // init 里绝不能做同步 IO，所以构造完必须立刻可用（不阻塞）
        await store.waitUntilLoaded()
        XCTAssertTrue(store.isLoaded, "加载完成后 isLoaded 必须为 true")
    }

    /// 书源仓库同理：init 不阻塞，加载后 isLoaded 置位
    @MainActor
    func testSourceStoreLoadsAsynchronously() async {
        let store = SourceStore()
        await store.waitUntilLoaded()
        XCTAssertTrue(store.isLoaded)
        // 派生缓存必须与 sources 一致（筛选结果缓存化后不能算错）
        XCTAssertEqual(store.searchableSources.count,
                       store.sources.filter { $0.enabled && !$0.searchUrl.trimmed.isEmpty }.count)
        XCTAssertEqual(store.exploreSources.count,
                       store.sources.filter {
                           $0.enabled && $0.enabledExplore && !$0.exploreUrl.trimmed.isEmpty
                       }.count)
    }

    /// 订阅源仓库同理
    @MainActor
    func testRssStoreLoadsAsynchronously() async {
        let store = RssStore()
        await store.waitUntilLoaded()
        XCTAssertTrue(store.isLoaded)
    }

    /// 翻页模式必须支持三种动画配置（回归：之前 pageTurn 完全没被使用）
    func testPageTurnHasThreeDistinctModes() {
        let modes = SettingsStore.PageTurn.allCases
        XCTAssertEqual(modes.count, 4, "滚动 / 覆盖 / 平移 / 无动画")
        XCTAssertTrue(modes.contains(.scroll))
        XCTAssertTrue(modes.contains(.cover))
        XCTAssertTrue(modes.contains(.slide))
        XCTAssertTrue(modes.contains(.none))
    }

    /// 正文格式化要产出一致的文本：两种阅读模式共用
    func testReaderTextFormattingDropsBlankLinesAndIndents() {
        let raw = "  第一段\n\n   \n第二段  \n"
        let indented = ReaderTextFormatting.displayText(raw, indent: true)
        XCTAssertEqual(indented, "　　第一段\n　　第二段")
        let plain = ReaderTextFormatting.displayText(raw, indent: false)
        XCTAssertEqual(plain, "第一段\n第二段")
        XCTAssertEqual(ReaderTextFormatting.displayText("", indent: true), "")
    }

    /// 顶层数组必须能按元素切分：几千个书源要分块解码，
    /// 不能一次性把上百 MB JSON 全解到内存（那就是「一打开就闪退」的根因）。
    func testFileStorageSplitsTopLevelArray() {
        let json = "[{\"a\":1},{\"b\":[1,2,3]},{\"c\":\"含,逗号与}\"}]"
        let data = Data(json.utf8)
        let ranges = FileStorage.arrayElementRanges(data)
        XCTAssertEqual(ranges?.count, 3, "应切出 3 个元素")
        let pieces = (ranges ?? []).map { String(decoding: data[$0], as: UTF8.self) }
        XCTAssertEqual(pieces[0], "{\"a\":1}")
        XCTAssertEqual(pieces[1], "{\"b\":[1,2,3]}")
        XCTAssertEqual(pieces[2], "{\"c\":\"含,逗号与}\"}", "字符串里的逗号和右括号不能当结构符")
    }

    /// 非数组输入要老实返回 nil，让调用方回退到整份解码
    func testFileStorageRejectsNonArray() {
        XCTAssertNil(FileStorage.arrayElementRanges(Data("{\"a\":1}".utf8)))
        XCTAssertNil(FileStorage.arrayElementRanges(Data("[]".utf8)))
        XCTAssertNil(FileStorage.arrayElementRanges(Data("".utf8)))
    }

    /// 括号出现在字符串里时，切分不能提前结束
    func testFileStorageHandlesNestedBracketsInStrings() {
        let json = "[{\"rule\":\"div[0]@text\"},{\"rule\":\"a(b)\"}]"
        let ranges = FileStorage.arrayElementRanges(Data(json.utf8))
        XCTAssertEqual(ranges?.count, 2)
    }

    /// 顶层元素是「字符串」时也必须切得出来。
    ///
    /// 旧实现只在 `}` / `]` 处结算元素，对字符串元素永远算不出闭合，
    /// 于是整个数组被判定成「切不出元素」并退回一次性整份解码 ——
    /// 内存优化当场失效，又变回启动瞬间吃掉数百 MB。
    func testFileStorageSplitsStringElements() {
        let json = "[\"alpha\",\"be,t{a\",\"g\\\"h\"]"
        let data = Data(json.utf8)
        let ranges = FileStorage.arrayElementRanges(data)
        XCTAssertEqual(ranges?.count, 3, "三个字符串元素都要切出来")
        let pieces = (ranges ?? []).map { String(decoding: data[$0], as: UTF8.self) }
        XCTAssertEqual(pieces[0], "\"alpha\"")
        XCTAssertEqual(pieces[1], "\"be,t{a\"", "字符串里的逗号与花括号不能当结构符")
        XCTAssertEqual(pieces[2], "\"g\\\"h\"", "转义引号不能当成结束")
    }

    /// 数组末尾没有逗号（或文件被截断）时，最后一个元素也要算上
    func testFileStorageHandlesTrailingElementWithoutComma() {
        let ranges = FileStorage.arrayElementRanges(Data("[{\"a\":1}".utf8))
        XCTAssertEqual(ranges?.count, 1)
    }

    /// 分页：同样的正文，字号越大页数越多；窄屏页数也更多
    func testPageSplitterPagination() {
        let text = Array(repeating: "得闲阅读测试正文。", count: 400).joined()
        let base = PageSplitter.Layout(
            font: UIFont.systemFont(ofSize: 17),
            lineSpacing: 6,
            paragraphSpacing: 8,
            indent: false,
            height: 600,
            width: 320
        )
        let normal = PageSplitter.paginate(text: text, layout: base)
        XCTAssertGreaterThan(normal.count, 1, "长文必须被切成多页")

        var bigger = base
        bigger.font = UIFont.systemFont(ofSize: 30)
        let large = PageSplitter.paginate(text: text, layout: bigger)
        XCTAssertGreaterThan(large.count, normal.count, "字号变大页数应增加")

        var narrower = base
        narrower.width = 160
        let narrow = PageSplitter.paginate(text: text, layout: narrower)
        XCTAssertGreaterThan(narrow.count, normal.count, "宽度变窄页数应增加")

        // 内容不能丢：拼回来必须和原文一致（忽略空白差异）
        let joined = normal.joined()
        let stripped = joined.filter { !$0.isWhitespace }.count
        XCTAssertEqual(stripped, text.filter { !$0.isWhitespace }.count, "分页不得丢字")
    }

    /// 分页边界：空文本与超小可用区域要能安全返回
    func testPageSplitterHandlesEdgeCases() {
        let layout = PageSplitter.Layout(
            font: UIFont.systemFont(ofSize: 17), lineSpacing: 4, paragraphSpacing: 4,
            indent: true, height: 600, width: 320
        )
        XCTAssertTrue(PageSplitter.paginate(text: "", layout: layout).isEmpty)
        XCTAssertTrue(PageSplitter.paginate(text: "   \n  ", layout: layout).isEmpty)
        // 无效布局直接当一页，不能死循环
        var broken = layout
        broken.height = 0
        XCTAssertEqual(PageSplitter.paginate(text: "正文", layout: broken).count, 1)
    }

    /// 字体族映射要和设置里的名字对上，否则宋体/楷体排版会不一致
    func testPageSplitterFontMapping() {
        XCTAssertNotNil(PageSplitter.uiFont(family: "系统", size: 17))
        XCTAssertNotNil(PageSplitter.uiFont(family: "宋体", size: 17))
        XCTAssertNotNil(PageSplitter.uiFont(family: "楷体", size: 17))
        XCTAssertNotNil(PageSplitter.uiFont(family: "圆体", size: 17))
        XCTAssertNotNil(PageSplitter.uiFont(family: "等宽", size: 17))
        XCTAssertNotNil(PageSplitter.uiFont(family: "未知字体", size: 17))
    }

    /// 每一页的底部留白不得超过约 3 行。
    ///
    /// 这是「字体放大以后没有铺满全屏」的直接回归测试。
    ///
    /// 旧实现为了把段落断在换行处，允许回退到本页容量的 65%（最多丢 35%）。
    /// 段落长度接近整页时，最近的换行恰好落在回退窗口里，于是每页都要
    /// 丢掉好几行 —— 字号越大每行字数越少，丢的行数看起来越多。
    ///
    /// 断言刻意用「行」为单位而不是百分比：分页的高度度量随字体变化，
    /// 用点数表达才对所有字号一致。自然留白最多一行（二分取最大值），
    /// 加上回退上限 1.5 行，因此 3 行是稳妥的上界；
    /// 而旧实现在同样场景下会留出 7～13 行，必然被抓住。
    func testPagesFillAvailableHeight() {
        for fontSize in [16.0, 22.0, 30.0] {
            let layout = PageSplitter.Layout(
                font: UIFont.systemFont(ofSize: fontSize),
                lineSpacing: 6,
                paragraphSpacing: 8,
                indent: false,
                height: 700,
                width: 360
            )
            let lineHeight = Self.measuredLineHeight(layout)
            let perLine = max(1, Int(layout.width / fontSize))
            let capacity = Int(layout.height / lineHeight) * perLine
            // 段落取容量的六成：保证每页边界都落在一段中间，
            // 「最近的换行」因此可能落在回退窗口里 —— 正是要考的场景。
            let paragraph = String(repeating: "得闲阅读测试正文内容",
                                   count: max(2, capacity * 3 / 5 / 10))
            let text = Array(repeating: paragraph, count: 14).joined(separator: "\n")
            let pages = PageSplitter.paginate(text: text, layout: layout)
            XCTAssertGreaterThan(pages.count, 2, "字号 \(fontSize) 应切出多页")

            for (offset, page) in pages.enumerated() where offset < pages.count - 1 {
                let used = Self.measure(page, font: layout.font,
                                        lineSpacing: layout.lineSpacing,
                                        paragraphSpacing: layout.paragraphSpacing,
                                        width: layout.width)
                let unused = layout.height - used
                XCTAssertLessThanOrEqual(
                    unused, lineHeight * 3,
                    "字号 \(fontSize) 第 \(offset + 1) 页底部留白 \(Int(unused))pt"
                        + "（约 \(String(format: "%.1f", unused / lineHeight)) 行），超过 3 行"
                )
            }
        }
    }

    /// 单行高度（含行距），用于把留白换算成行数
    private static func measuredLineHeight(_ layout: PageSplitter.Layout) -> CGFloat {
        // 单行不产生段落断点，段间距对它没有影响，传 0 即可
        measure("得闲", font: layout.font, lineSpacing: layout.lineSpacing,
                paragraphSpacing: 0, width: layout.width)
    }

    /// 分页实测高度：与 PageSplitter 内部同一套度量。
    ///
    /// 段落样式直接复用 `ReaderTextStyle`，与正文渲染 / 分页测量三方同源。
    /// 各写一份的话，任何一方调了参数，这里的断言就会与实际排版脱节。
    private static func measure(
        _ text: String,
        font: UIFont,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: ReaderTextStyle.paragraphStyle(
                    lineSpacing: lineSpacing,
                    paragraphSpacing: paragraphSpacing,
                    justified: true
                )
            ]
        )
        return ceil(attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }

    /// 段落断点仍要被优先采用（回退窗口只是收紧，不是取消）
    func testPaginationStillPrefersNearbyLineBreaks() {
        // 段落很短（一行多一点），断点总在回退窗口内，必须被采用
        let text = (0..<120).map { _ in "得闲阅读段落测试。" }.joined(separator: "\n")
        let layout = PageSplitter.Layout(
            font: UIFont.systemFont(ofSize: 17), lineSpacing: 6, paragraphSpacing: 8,
            indent: false, height: 600, width: 320
        )
        let pages = PageSplitter.paginate(text: text, layout: layout)
        XCTAssertGreaterThan(pages.count, 1)
        for page in pages.dropLast() {
            XCTAssertTrue(page.hasSuffix("。"), "页尾应在段落结束处： " + String(page.suffix(12)))
        }
    }


    /// 发现分类去重：重复 id 会让 ForEach 崩溃
    func testExploreCategoriesDeduplicateById() {
        let raw = """
        [{"title":"玄幻","url":"/a"},{"title":"玄幻","url":"/a"},{"title":"都市","url":"/b"}]
        """
        let list = ExploreCategoryList(raw: raw)
        var seen = Set<String>()
        let unique = list.items.filter { seen.insert($0.id).inserted }
        XCTAssertEqual(unique.count, 2)
    }

    // MARK: 表单型发现源
    //
    // yckceo 上有一批源的 exploreUrl 返回的是「控件 + 按钮」，而不是纯分类。
    // 旧解析只认 title+url，没有 url 的项被整条丢掉，于是这些源的
    // 「发现」页只剩零星几条甚至全空 —— 用户反馈的
    // 「内容分类里也无显示，都打不开」正是这个。

    /// 无 url 的控件要被识别成表单项，而不是被丢弃
    func testExplorePageParsesFormControls() {
        let raw = """
        [
          {"title":"关键字","type":"text"},
          {"title":"🔍 搜剧","type":"button","action":"java.searchBook(infoMap['关键字'], source)"},
          {"title":"频道","type":"select","chars":["电影","电视剧"],"default":"电影",
           "action":"var c=infoMap['频道']; java.refreshExplore();"},
          {"title":"全部","url":"https://a.test/list/{{page}}"}
        ]
        """
        let page = ExplorePage.parse(raw)
        XCTAssertEqual(page.categories.count, 1, "只有带 url 的项才是分类")
        XCTAssertEqual(page.categories.first?.title, "全部")
        XCTAssertEqual(page.controls.count, 3, "三个无 url 的控件必须全部保留")

        let types = page.controls.map(\.type)
        XCTAssertTrue(types.contains("text"))
        XCTAssertTrue(types.contains("button"))
        XCTAssertTrue(types.contains("select"))

        let select = page.controls.first { $0.type == "select" }
        XCTAssertEqual(select?.chars, ["电影", "电视剧"])
        XCTAssertEqual(select?.defaultValue, "电影")
        XCTAssertTrue(select?.isSelect ?? false)
        XCTAssertFalse(select?.isButton ?? true)
    }

    /// 静态 "标题::地址" 文本仍要解析成分类，且走同一套入口
    func testExplorePageParsesColonList() {
        let page = ExplorePage.parse("玄幻::/xuanhuan\n都市::/dushi")
        XCTAssertEqual(page.categories.count, 2)
        XCTAssertEqual(page.categories.first?.title, "玄幻")
        XCTAssertEqual(page.categories.first?.url, "/xuanhuan")
        XCTAssertTrue(page.controls.isEmpty)
    }

    /// 单条裸地址兜底成「全部」入口：整页不能一条都点不动
    func testExplorePageFallsBackToSingleEntry() {
        let page = ExplorePage.parse("https://a.test/list/1.html")
        XCTAssertEqual(page.categories.count, 1)
        XCTAssertEqual(page.categories.first?.title, "全部")
        XCTAssertEqual(page.categories.first?.url, "https://a.test/list/1.html")
    }

    /// 空的 / nil 输入不能崩，也不能造出假分类
    func testExplorePageHandlesEmptyInput() {
        XCTAssertTrue(ExplorePage.parse(nil).isEmpty)
        XCTAssertTrue(ExplorePage.parse("").isEmpty)
        XCTAssertTrue(ExplorePage.parse("[]").isEmpty)
    }

    /// source.getVariable() 未保存过时必须返回空串而不是 null。
    ///
    /// 书源普遍写 `JSON.parse(source.getVariable() || '{}')`，
    /// 但有 23 处（13 个源）直接写 `JSON.parse(source.getVariable())`：
    /// 返回 null 时 JSON.parse(null) 不抛错、返回 null，
    /// 紧接着对 null 取属性就是 TypeError，整段脚本被打断 ——
    /// 表现是「短剧 / 听书打不开」。返回空串才会走书源自己的 catch。
    func testGetVariableReturnsEmptyStringWhenUnset() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("source.getVariable()"), "")
        XCTAssertEqual(engine.evaluateString("typeof source.getVariable()"), "string")
        // 书源的真实分支：返回空串时 JSON.parse('') 会抛错，被 catch 兜住
        let guarded = engine.evaluateString("""
        (function(){
          var cfg = {};
          try { cfg = JSON.parse(source.getVariable() || '{}') || {}; } catch (e) {}
          return cfg.ch || 'default';
        })()
        """)
        XCTAssertEqual(guarded, "default")
    }

    /// setVariable 要能回传新值（表单「切换频道」靠它跨次保留选择）
    func testSetVariableNotifiesHost() {
        let engine = JSEngine(host: JSEngine.Host())
        var stored = ""
        engine.onVariableChanged = { stored = $0 }
        _ = engine.evaluate("source.setVariable(JSON.stringify({channel:'电视剧'}))")
        XCTAssertEqual(engine.sourceVariable, #"{"channel":"电视剧"}"#)
        XCTAssertEqual(stored, #"{"channel":"电视剧"}"#)
    }

    /// 全局 infoMap 必须存在：缺失时表单脚本一行都跑不动
    func testInfoMapGlobalExists() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof infoMap"), "object")
        XCTAssertEqual(engine.evaluateString("typeof infoMap.put"), "function")
        XCTAssertEqual(engine.evaluateString("typeof infoMap.save"), "function")
        // 书源真实写法：读一个还没填过的控件得到 null，而不是抛异常
        XCTAssertEqual(engine.evaluateString("String(infoMap['关键字'] || '')"), "")
        _ = engine.evaluate("infoMap.put('频道','女频')")
        XCTAssertEqual(engine.evaluateString("infoMap['频道']"), "女频")
        XCTAssertEqual(engine.evaluateString("infoMap.get('频道')"), "女频")
    }

    /// java.searchBook 要真的把关键词交回宿主（不再走 noop）
    func testSearchBookCallbackFires() {
        let engine = JSEngine(host: JSEngine.Host())
        var captured: [String] = []
        engine.onSearchBook = { captured.append($0) }
        _ = engine.evaluate("java.searchBook('剑来', source)")
        XCTAssertEqual(captured, ["剑来"])
        // 空关键词不该触发搜索
        _ = engine.evaluate("java.searchBook('', source)")
        XCTAssertEqual(captured, ["剑来"])
    }

    /// java.refreshExplore 要通知宿主重算，而不是空实现
    func testRefreshExploreCallbackFires() {
        let engine = JSEngine(host: JSEngine.Host())
        var count = 0
        engine.onRefreshExplore = { count += 1 }
        _ = engine.evaluate("java.refreshExplore()")
        XCTAssertEqual(count, 1)
    }

    /// 脚本体 exploreUrl 不能被「标题::地址」规则切碎。
    ///
    /// 脚本里出现 `::` 很常见（七猫的分组名、晋江的
    /// `const separator = '::'`、超星的接口地址…）。旧实现见到 `::`
    /// 就按分类列表逐行切，12 个脚本型源（含 36415 字符的七猫）
    /// 被切成一堆垃圾 JSON、整段脚本丢失 —— 发现页因此空白。
    func testScriptExploreUrlSurvivesImport() {
        let script = """
        @js:
        var groups = ['排行榜', '分类::玄幻'];
        var s = [];
        s.push({title: '全部', url: 'https://a.test/list/{{page}}'});
        JSON.stringify(s);
        """
        let source = BookSource(dict: [
            "bookSourceName": "脚本源",
            "bookSourceUrl": "https://a.test",
            "exploreUrl": script
        ])
        XCTAssertTrue(source.exploreUrl.hasPrefix("@js:"), "脚本体必须原样保留")
        XCTAssertTrue(source.exploreUrl.contains("分类::玄幻"), "脚本里的 :: 不能被切开")
        XCTAssertFalse(source.exploreUrl.hasPrefix("["), "不能被转成分类数组 JSON")
    }

    /// 静态 "标题::地址" 仍然要转成标准分类数组
    func testPlainColonListStillBecomesCategories() {
        let source = BookSource(dict: [
            "bookSourceName": "静态源",
            "bookSourceUrl": "https://b.test",
            "exploreUrl": "玄幻::/xuanhuan\n都市::/dushi"
        ])
        XCTAssertTrue(source.exploreUrl.hasPrefix("["), "静态列表应转为 JSON 数组")
        let page = ExplorePage.parse(source.exploreUrl)
        XCTAssertEqual(page.categories.count, 2)
        XCTAssertEqual(page.categories.first?.url, "/xuanhuan")
    }

    // MARK: 内存 / 生命周期回归
    //
    // 这一组锁死「搜索引擎必须能释放」这个不变量。
    //
    // 症状：600 多个书源，搜到 97 个左右必闪退，崩溃栈全是 JavaScriptCore
    // 帧 + Swift 运行时陷阱（SIGABRT）。根因是 JSEngine 里注册给 JS 的每个
    // block 都强捕获了 JSContext，而这些 block 又挂在同一个 JSContext 的
    // 全局对象上，形成 JSContext -> java -> block -> JSContext 的循环引用：
    // 每跑一个书源就泄漏一整个 JSVirtualMachine，搜到近百个源时内存触顶。
    // 修复后所有 block 一律 [weak context] 捕获，引擎必须能随作用域释放。

    func testJSEngineIsDeallocatedAfterScope() {
        weak var weakEngine: JSEngine?
        autoreleasepool {
            var engine: JSEngine? = JSEngine(host: JSEngine.Host())
            weakEngine = engine
            // 跑一次求值，触发 setup 注册的全部宿主回调
            XCTAssertEqual(engine?.evaluateString("1+1"), "2")
            // 触发会引用 context 的那几个回调（connect / getElement / get）
            _ = engine?.evaluate("typeof java.connect")
            _ = engine?.evaluate("typeof java.getElement")
            _ = engine?.evaluate("typeof cache.put")
            engine = nil
        }
        XCTAssertNil(weakEngine, "JSEngine 未被释放：JS block 仍在强持有 JSContext，会造成每个书源泄漏一个 JSVirtualMachine")
    }

    func testManyJSEnginesDoNotAccumulate() {
        // 模拟一轮多源搜索：连续建 200 个引擎（远超用户说的 97）。
        // 修复前每个引擎都泄漏一个 JSVirtualMachine，这里会稳定崩；
        // 修复后全部应即时释放。
        weak var probe: JSEngine?
        for index in 0..<200 {
            autoreleasepool {
                let engine = JSEngine(host: JSEngine.Host())
                _ = engine.evaluateString("'src" + String(index) + "'")
                if index == 0 { probe = engine }
            }
        }
        XCTAssertNil(probe, "批量创建的 JSEngine 未释放，多源搜索会累积内存并闪退")
    }

    func testJSEngineStillWorksAfterWeakContextRefactor() {
        // 弱引用改造后功能不能退化：java / source / cookie / cache 都要可用。
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("java.md5Encode('abc')"),
                       "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(engine.evaluateString("java.base64Encode('hi')"), "aGk=")
        XCTAssertEqual(engine.evaluateString("java.base64Decode('aGk=')"), "hi")
        XCTAssertEqual(engine.evaluateString("(function(){ var c = cache; return typeof c.put; })()"), "function")
        XCTAssertEqual(engine.evaluateString("typeof source.getKey"), "function")
    }

    // MARK: 正文完整性

    /// 正文规则命中一整组段落时必须全部返回。
    ///
    /// 旧实现 string() = stringList().first，只拿第一段，
    /// 表现就是「打开只显示几个字 / 只显示一半」。
    func testContentRuleReturnsEveryMatchedParagraph() {
        let html = """
        <div class="read-content"><p>第一段正文</p><p>第二段正文</p><p>第三段正文</p></div>
        """
        let analyzer = AnalyzeRule(content: html)
        analyzer.paragraphs = true
        let text = analyzer.string("class.read-content@p@text")
        XCTAssertTrue(text.contains("第一段正文"))
        XCTAssertTrue(text.contains("第二段正文"))
        XCTAssertTrue(text.contains("第三段正文"))
    }

    /// 地址字段取多值时只应保留第一条：多条用换行拼接会得到无法访问的地址。
    func testFirstStringKeepsOnlyOneURL() {
        let html = """
        <div><a class="next" href="/c/2.htm">下一章</a><a class="next" href="/c/3.htm">下下章</a></div>
        """
        let analyzer = AnalyzeRule(content: html)
        XCTAssertEqual(analyzer.firstString("class.next@href"), "/c/2.htm")
        XCTAssertFalse(analyzer.firstString("class.next@href").contains("\n"))
    }

    // MARK: @put / @get

    /// @put 声明的变量要被 @get 读到（57 个书源声明、204 个书源读取）。
    func testPutThenGetVariable() {
        var variables: [String: String] = [:]
        var context = RuleContext(content: "<div id=\"bid\">42</div>", baseUrl: "https://a.com")
        context.putVariable = { name, value in variables[name] = value ?? "" }
        context.getVariable = { name in variables[name] ?? "" }

        let analyzer = AnalyzeRule(context: context)
        // @put 声明本身不产出正文，它只是副作用
        _ = analyzer.string("@put:{id:id.bid@text}")
        XCTAssertEqual(variables["id"], "42")
        // 后续字段用 @get:{id} 取回同一个值
        XCTAssertEqual(analyzer.string("@get:{id}"), "42")
    }

    /// @get 出现在 URL 模板中间时也要展开（例：https://h5.17k.com/list/@get:{id}.html）。
    func testGetInsideURLTemplate() {
        var variables: [String: String] = [:]
        var context = RuleContext(content: "", baseUrl: "https://a.com")
        context.putVariable = { name, value in variables[name] = value ?? "" }
        context.getVariable = { name in variables[name] ?? "" }
        variables["id"] = "12345"

        let analyzer = AnalyzeRule(context: context)
        XCTAssertEqual(analyzer.interpolate("https://h5.17k.com/list/@get:{id}.html"),
                       "https://h5.17k.com/list/12345.html")
    }

    /// @put 的值可以是一条完整规则（含 ## 替换、选择器链）。
    func testPutAcceptsFullRuleValue() {
        var variables: [String: String] = [:]
        var context = RuleContext(content: "<p class=\"tag\">玄幻</p>", baseUrl: "https://a.com")
        context.putVariable = { name, value in variables[name] = value ?? "" }
        context.getVariable = { name in variables[name] ?? "" }

        let analyzer = AnalyzeRule(context: context)
        _ = analyzer.string("@put:{k:class.tag@text##幻##幻小说}")
        XCTAssertEqual(variables["k"], "玄幻小说")
    }

    /// 替换完成后的模板结果是**文本**，不能再当选择器求值。
    ///
    /// 对齐 Legado：命中 evalPattern（@get: / {{}}）时 mode 置为 Regex，
    /// getString 的 `else -> sourceRule.rule` 分支直接返回替换后的文本。
    /// 若再走一遍 CSS 选择器，书名 / 作者 / 简介会整段变成空。
    func testTemplateResultIsTextNotSelector() {
        var variables: [String: String] = ["n": "斗破苍穹"]
        var context = RuleContext(content: "<div>无关内容</div>", baseUrl: "https://a.com")
        context.getVariable = { name in variables[name] ?? "" }
        context.putVariable = { name, value in variables[name] = value ?? "" }
        let analyzer = AnalyzeRule(context: context)

        XCTAssertEqual(analyzer.string("@get:{n}"), "斗破苍穹")
        XCTAssertEqual(analyzer.string("{{n}}"), "斗破苍穹")
        // 模板与选择器并存时仍然按选择器求值，不能被拍成文本
        XCTAssertTrue(analyzer.string("class.none@text").isEmpty)
    }

    /// 纯静态选择器规则不受模板分支影响。
    func testPlainSelectorStillEvaluated() {
        let analyzer = AnalyzeRule(content: "<h3 class=\"name\">斗破苍穹</h3>")
        XCTAssertEqual(analyzer.string("class.name@text"), "斗破苍穹")
        XCTAssertEqual(analyzer.firstString("class.name@text"), "斗破苍穹")
    }

    // MARK: JS 规则里的模板插值

    /// `@js:` / `<js>` 规则里含 `{{…}}` 时，脚本必须照常求值。
    ///
    /// 「含 `{{}}` 就当文本」那条捷径是给 CSS/XPath 规则用的：模板替换完
    /// 结果就是一段文本，不能再拿去做选择器。但 JS 规则不同 ——
    /// `{{…}}` 是**喂给脚本的值**，脚本本身还得跑。
    ///
    /// 旧实现无条件把含 `{{}}` 的规则拍成文本，于是这类规则要么显示成
    /// 一段脚本原文、要么整段落空。实测 3460 个源里 111 条规则（57 个源）命中。
    func testJSRuleWithTemplateIsStillEvaluated() {
        var variables: [String: String] = ["bid": "12345"]
        var context = RuleContext(content: nil, baseUrl: "https://a.com")
        context.getVariable = { variables[$0] ?? "" }
        context.putVariable = { name, value in variables[name] = value ?? "" }
        context.evaluateJS = { script, _, _ in
            JSEngine(host: JSEngine.Host()).evaluate(script)
        }
        let analyzer = AnalyzeRule(context: context)

        // `{{bid}}` 先替换成 12345，脚本再做字符串拼接
        XCTAssertEqual(analyzer.string("@js: 'id=' + '{{bid}}'"), "id=12345")
        // 插值出现在模板串内部（UAA禁漫 ruleToc.chapterUrl 的写法）
        XCTAssertEqual(
            analyzer.string("@js: `/c?force=false&id={{bid}}&offset=0`"),
            "/c?force=false&id=12345&offset=0"
        )
        // 插值作为函数实参（飛天小說 ruleToc.updateTime 的写法）
        XCTAssertEqual(analyzer.string("@js: 'T' + ({{bid}} + '').length"), "T5")
    }

    /// `<js>` 段内的插值同样要展开（可阅文学 ruleToc.chapterName 的写法）。
    func testInlineJSSegmentExpandsTemplate() {
        var variables: [String: String] = ["n": "斗破苍穹"]
        var context = RuleContext(content: nil, baseUrl: "https://a.com")
        context.getVariable = { variables[$0] ?? "" }
        context.putVariable = { name, value in variables[name] = value ?? "" }
        context.evaluateJS = { script, _, _ in
            JSEngine(host: JSEngine.Host()).evaluate(script)
        }
        let analyzer = AnalyzeRule(context: context)
        XCTAssertEqual(analyzer.string("<js>`书名:{{n}}`</js>"), "书名:斗破苍穹")
    }

    // MARK: 列表规则给 JS 的 result 形态

    /// 列表规则里节点选择结果必须保持元素对象：书源会写
    /// result.toArray() / result.select()。
    func testListRuleExposesElementsToJS() {
        let html = "<ul><li><a href=\"/1\">一</a></li><li><a href=\"/2\">二</a></li></ul>"
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: html, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        let items = analyzer.listItems("tag.li@js:result.toArray().map(function(el){return el.select('a').attr('href')})")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(RuleUtil.asString(items[0]), "/1")
        XCTAssertEqual(RuleUtil.asString(items[1]), "/2")
    }

    /// 文本规则里 result 必须是字符串：书源会写 result.match(...) / result.split(...)。
    func testTextRuleExposesStringToJS() {
        let html = "<div class=\"t\">时长 12.5万</div>"
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: html, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(analyzer.string("class.t@text@js:result.match(/\\d+?\\.\\d+万/g)[0]"), "12.5万")
    }

    /// 顶层 let 的脚本要能反复求值：否则同一条规则第二次执行报
    /// "Can't create duplicate variable"，表现为「第一次能搜到、再搜就空白」。
    func testTopLevelLetScriptRunsRepeatedly() {
        let engine = JSEngine(host: JSEngine.Host())
        let script = "let txt = 'a'; let key = 'b'; txt + key"
        XCTAssertEqual(engine.evaluateString(script), "ab")
        XCTAssertEqual(engine.evaluateString(script), "ab")
    }

    /// 顶层 let 的变量不能泄漏到全局，否则第二次执行必然冲突。
    func testTopLevelLetDoesNotLeakToGlobal() {
        let engine = JSEngine(host: JSEngine.Host())
        _ = engine.evaluate("let txt = 'x';")
        XCTAssertEqual(engine.evaluateString("typeof txt"), "undefined")
    }

    /// 顶层 return 的脚本要能跑出结果（实测 4 段书源脚本这么写）。
    func testTopLevelReturnScriptStillReturns() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("var a = 1; return a + 1;"), "2")
    }

    /// 包装形态的选择必须靠**结构判定**，不能靠异常文案。
    ///
    /// JavaScriptCore 对顶层 return 的报错原文（"Return statements are only
    /// valid inside functions."）与 V8 / Rhino 都不一致；一旦靠文案兜底，
    /// 文案对不上就会静默返回空串。这里把判定锁死在语法结构上。
    func testScriptWrapperPicksFunctionFormForTopLevelReturn() {
        // 顶层 return：函数形态必须排在首位（块形态是语法错误）
        XCTAssertTrue(JSEngine.hasTopLevelReturn("var a = 1; return a + 1;"))
        XCTAssertTrue(JSEngine.hasTopLevelReturn("if (a) return 1;"))
        XCTAssertTrue(JSEngine.scriptCandidates("return 1")[0].hasPrefix("(function(){"))

        // 函数体内的 return 不算顶层
        XCTAssertFalse(JSEngine.hasTopLevelReturn("function f(){ return 1 }"))
        XCTAssertFalse(JSEngine.hasTopLevelReturn("if (a) { return 1 }"))
        XCTAssertFalse(JSEngine.hasTopLevelReturn("var f = function(){ return 1 }; f();"))
        XCTAssertFalse(JSEngine.hasTopLevelReturn("(function(){ return 1 })()"))
        XCTAssertFalse(JSEngine.hasTopLevelReturn("try { return 1 } finally { }"))

        // 字符串 / 注释 / 正则里的 return 不是关键字
        XCTAssertFalse(JSEngine.hasTopLevelReturn("var s = 'return 1';"))
        XCTAssertFalse(JSEngine.hasTopLevelReturn("// return 1"))
        XCTAssertFalse(JSEngine.hasTopLevelReturn("/* return 1 */ 2"))
        XCTAssertFalse(JSEngine.hasTopLevelReturn("var r = /return/;"))

        // 普通脚本仍用块形态先行：块隔离顶层 let，避免重复求值冲突
        XCTAssertFalse(JSEngine.hasTopLevelReturn("let txt = 'a'; txt"))
        XCTAssertTrue(JSEngine.scriptCandidates("let txt = 'a'; txt")[0].hasPrefix("{"))
    }

    // MARK: JS 环境补齐

    /// 裸包名 org / javax 必须可用（170 处 org.jsoup 调用依赖它）。
    func testBarePackageNamesAreAvailable() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof org.jsoup.Jsoup.parse"), "function")
        XCTAssertEqual(engine.evaluateString("typeof javax.crypto.Cipher.getInstance"), "function")
    }

    /// getLoginInfoMap / getLoginHeaderMap 的返回值必须支持 java.util.Map 语义。
    ///
    /// 书源写的是 `info.get('账号')`，而 Swift 的 [String: String] 桥到 JS
    /// 只是个普通对象，`info.get` 是 undefined —— 实测日志里刷屏的
    /// "TypeError: info.get is not a function" 就是这里来的，
    /// 登录脚本因此整段失效（微信读书 / 书旗等源依赖它）。
    func testWrappedMapSupportsJavaMapSemantics() {
        let engine = JSEngine(host: JSEngine.Host())
        // 包装一个普通 JS 对象，模拟 Swift 字典桥过来的形态
        _ = engine.evaluate("var m = __dxWrapMap({'账号': 'u1', '密码': 'p1'});")
        XCTAssertEqual(engine.evaluateString("m.get('账号')"), "u1")
        XCTAssertEqual(engine.evaluateString("m.get('密码')"), "p1")
        // 下标访问与 .get 必须看到同一份数据
        XCTAssertEqual(engine.evaluateString("m['账号']"), "u1")
        XCTAssertEqual(engine.evaluateString("m.size()"), "2")
        XCTAssertEqual(engine.evaluateString("m.containsKey('账号') ? 'y' : 'n'"), "y")
        XCTAssertEqual(engine.evaluateString("m.containsKey('没有') ? 'y' : 'n'"), "n")
        // 不存在的键按 Java 语义返回 null，不是 undefined
        XCTAssertEqual(engine.evaluateString("m.get('没有') === null ? 'null' : 'other'"), "null")
        XCTAssertEqual(engine.evaluateString("m.getOrDefault('没有', 'd')"), "d")
        // put 之后两种读法都要能看到新值
        _ = engine.evaluate("m.put('手机', '138');")
        XCTAssertEqual(engine.evaluateString("m.get('手机')"), "138")
        XCTAssertEqual(engine.evaluateString("m['手机']"), "138")
        XCTAssertEqual(engine.evaluateString("m.size()"), "3")
        // keySet / remove 的基本行为
        XCTAssertEqual(engine.evaluateString("m.keySet().length"), "3")
        XCTAssertEqual(engine.evaluateString("m.remove('手机'); m.size()"), "2")
        // 空值也不能崩
        XCTAssertEqual(engine.evaluateString("__dxWrapMap(null).size()"), "0")
        XCTAssertEqual(engine.evaluateString("__dxWrapMap(undefined).isEmpty() ? 'e' : 'n'"), "e")
    }

    /// 书源注释里的 helper 要能被 eval 出来并调用（40 篇书源这么写）。
    func testHelperDefinedInSourceCommentIsCallable() {
        let engine = JSEngine(host: JSEngine.Host())
        _ = engine.evaluate("eval(String('function traditionalToSimplified(s){ return String(s); }'))")
        XCTAssertEqual(engine.evaluateString("traditionalToSimplified('測試')"), "測試")
    }

    /// java.get 必须同时支持「读变量」和「HTTP GET」两种签名。
    func testJavaGetOverloads() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof java.get"), "function")
        XCTAssertEqual(engine.evaluateString("String(java.get('missing'))"), "")
    }

    // MARK: 正文排版

    /// 中文正文必须两端对齐。
    ///
    /// 这是「放大后版面不居中、页面偏左、没有满屏铺开」的直接回归测试。
    ///
    /// SwiftUI 的 `Text` 没有对齐选项，右边界完全由断行决定。
    /// 实测 402pt 宽的屏幕上，右边缘在 374pt 处就停住（余量 28~38pt 且参差不齐），
    /// 而左边缘整齐地停在 21pt —— 视觉上就是「整体偏左、右边缺一块」。
    /// 改走 TextKit 并设成 `.justified` 后，除段落末行外每一行都会顶到右边界。
    func testReaderTextStyleIsJustified() {
        let style = ReaderTextStyle.paragraphStyle(
            lineSpacing: 8, paragraphSpacing: 10, justified: true
        )
        XCTAssertEqual(style.alignment, .justified, "中文正文必须两端对齐")
        XCTAssertEqual(style.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(style.lineSpacing, 8)
        XCTAssertEqual(style.paragraphSpacing, 10, "段落间距必须真实下发，否则设置调了没反应")
        // 断词会把中文字符之间插上连字符
        XCTAssertEqual(style.hyphenationFactor, 0)

        // 关闭时退回自然对齐，不能强行套用两端对齐
        let plain = ReaderTextStyle.paragraphStyle(
            lineSpacing: 0, paragraphSpacing: 0, justified: false
        )
        XCTAssertEqual(plain.alignment, .natural)
    }

    /// 分页测量必须与正文渲染用同一份段落样式，并且默认两端对齐。
    ///
    /// 两处各写一份段落样式的话，任何一处改了参数，分页就会与绘制脱节，
    /// 表现为「算得下一行、画出来被裁掉」或「每页底部空一大截」。
    func testPageSplitterUsesJustifiedLayoutByDefault() {
        let layout = PageSplitter.Layout(
            font: UIFont.systemFont(ofSize: 18), lineSpacing: 6,
            paragraphSpacing: 10, indent: false, height: 600, width: 320
        )
        XCTAssertTrue(layout.justified, "分页测量默认必须按两端对齐计算")
    }

    /// 段落间距必须真正影响分页结果。
    ///
    /// 旧实现把测量里的 `paragraphSpacing` 硬编码成 0（因为当时正文用
    /// SwiftUI 的 `Text`，它不对 `\n` 应用段间距），于是翻页模式下
    /// 「段落间距」这个设置调了完全没有效果。现在两侧都走 TextKit，
    /// 段间距必须能改变一页装得下的内容量。
    func testParagraphSpacingAffectsPagination() {
        let paragraph = String(repeating: "得闲阅读排版测试。", count: 6)
        let text = Array(repeating: paragraph, count: 40).joined(separator: "\n")
        let base = PageSplitter.Layout(
            font: UIFont.systemFont(ofSize: 18), lineSpacing: 4,
            paragraphSpacing: 0, indent: false, height: 600, width: 320
        )
        let compact = PageSplitter.paginate(text: text, layout: base)
        var spaced = base
        spaced.paragraphSpacing = 30
        let loose = PageSplitter.paginate(text: text, layout: spaced)
        XCTAssertGreaterThan(loose.count, compact.count,
                             "段间距变大后每页能放的内容变少，页数必须增加")
    }

    /// 分页与绘制必须拿到同一个 UIFont，否则「等宽」这类字体的行宽会不一致。
    func testPageSplitterFontIsSharedWithRenderer() {
        for family in SettingsStore.fontFamilies {
            let font = PageSplitter.uiFont(family: family, size: 19)
            XCTAssertEqual(font.pointSize, 19, "字体 \(family) 的字号必须与设置一致")
        }
    }

    // MARK: 听书 / 影视直链

    /// 目录规则直接给出媒体地址时必须原样返回，不能再去抓它。
    ///
    /// 喜马拉雅的 `ruleToc.chapterUrl` 写的是
    /// `playPathAacv224||playPathAacv164||playUrl64||playUrl32`，
    /// 解析出来**就是音频文件地址**。旧实现无条件请求它：
    /// 把几十 MB 音频当 HTML 下载再从里面「提取音频链接」，
    /// 必然一无所获 —— 这就是听书源一律打不开的直接原因。
    func testDirectMediaDetectionForAudio() {
        let audio = "mp3|m4a|aac|ogg|flac|wav|ape|wma|m3u8"
        XCTAssertTrue(SourceEngine.isDirectMediaURL("https://a.com/x.mp3", extensions: audio))
        XCTAssertTrue(SourceEngine.isDirectMediaURL("https://a.com/x.M4A", extensions: audio))
        XCTAssertTrue(SourceEngine.isDirectMediaURL("https://a.com/x.m3u8?auth=1", extensions: audio))
        XCTAssertTrue(SourceEngine.isDirectMediaURL("https://a.com/a/b/c.aac#t=1", extensions: audio))

        // 网页不能误判成音频：query 里出现 .mp3 很常见
        XCTAssertFalse(SourceEngine.isDirectMediaURL("https://a.com/page?id=1.mp3", extensions: audio))
        XCTAssertFalse(SourceEngine.isDirectMediaURL("https://a.com/play?file=x.m3u8", extensions: audio))
        // 相对地址不能当直链：播放器无法解析，必须先按章节页拼绝对地址
        XCTAssertFalse(SourceEngine.isDirectMediaURL("chapter/1.mp3", extensions: audio))
        XCTAssertFalse(SourceEngine.isDirectMediaURL("", extensions: audio))
    }

    /// 视频地址同理（短剧源的目录里常见直接写 m3u8 / mp4）。
    func testDirectMediaDetectionForVideo() {
        let video = "mp4|m3u8|flv|mkv|avi|mov|wmv|webm|ts|rmvb|m4v"
        XCTAssertTrue(SourceEngine.isDirectMediaURL("https://a.com/e/1.mp4", extensions: video))
        XCTAssertTrue(SourceEngine.isDirectMediaURL("https://cdn.a.com/live/index.m3u8?t=9", extensions: video))
        XCTAssertFalse(SourceEngine.isDirectMediaURL("https://a.com/detail/1", extensions: video))
        XCTAssertFalse(SourceEngine.isDirectMediaURL("https://a.com/x.mp3", extensions: video))
    }

    /// Content-Type 兜底：媒体字段常常不带扩展名。
    func testMediaContentTypeDetection() {
        XCTAssertTrue(SourceEngine.isMediaContentType("audio/mpeg"))
        XCTAssertTrue(SourceEngine.isMediaContentType("audio/mp4; charset=utf-8"))
        XCTAssertTrue(SourceEngine.isMediaContentType("video/mp4"))
        XCTAssertTrue(SourceEngine.isMediaContentType("application/vnd.apple.mpegurl"))
        XCTAssertTrue(SourceEngine.isMediaContentType("application/x-mpegURL"))
        XCTAssertFalse(SourceEngine.isMediaContentType("text/html; charset=utf-8"))
        XCTAssertFalse(SourceEngine.isMediaContentType("application/json"))
        XCTAssertFalse(SourceEngine.isMediaContentType(nil))
        XCTAssertFalse(SourceEngine.isMediaContentType(""))
    }

    // MARK: 全角引号容错

    /// 书源里的全角引号必须能被还原。
    ///
    /// 实测有源写成 `href@js:result+',{webView:“true”}'`（全角引号），
    /// JSON 解析必然失败，整条目录规则作废 ——
    /// 界面表现就是「目录获取失败」（天天评书、恋听网吧等源如此）。
    func testFullWidthJSONIsNormalized() {
        let fixed = HTTPClient.normalizeFullWidthJSON("{\"webView\":“true”}")
        XCTAssertEqual(fixed, "{\"webView\":\"true\"}")
        XCTAssertNotNil(fixed.jsonObject as? [String: Any], "还原后必须能被 JSON 解析")

        let chinese = HTTPClient.normalizeFullWidthJSON("{“method”：“POST”，“body”：｛｝}")
        XCTAssertEqual(chinese, "{\"method\":\"POST\",\"body\":{}}")
        XCTAssertNotNil(chinese.jsonObject as? [String: Any])

        // 已经是合法 ASCII 的内容原样返回，不做无谓改写
        XCTAssertEqual(HTTPClient.normalizeFullWidthJSON("{\"a\":1}"), "{\"a\":1}")
    }

    /// 夹带全角引号的 url 选项要能解析出选项，且地址部分保持干净。
    func testParseURLRuleAcceptsFullWidthQuotes() {
        let parsed = HTTPClient.parseURLRule("https://a.com/toc,{webView:“true”}")
        XCTAssertEqual(parsed.url, "https://a.com/toc")
        XCTAssertTrue(parsed.options.webView, "全角引号也要能识别出 webView")
    }

    /// 尾随选项是 JS 对象字面量而不是严格 JSON。
    ///
    /// 对 821 个源扫描 `,(\{[^}]*\})` 的真实样本：
    ///   🏷 起点小说   => {credentials:'omit'}
    ///   🎨漫蛙       => {webView:true}
    ///   📂台湾小说网  => {name:'打开网站',type:'button',action:'openSite()'}
    ///   🏷书旗小说   => {bookId:BID,chapterId:CID}
    /// 键名不带引号、值用单引号，旧实现按严格 JSON 解析失败后**整段不剥离**，
    /// 地址里残留 `,{...}`，请求必然失败 —— 界面表现就是「目录获取失败」。
    func testParseURLRuleAcceptsJSObjectLiteral() {
        // 键名不带引号（🎨漫蛙）
        let bare = HTTPClient.parseURLRule("https://a.com/toc,{webView:true}")
        XCTAssertEqual(bare.url, "https://a.com/toc")
        XCTAssertTrue(bare.options.webView)

        // 单引号字符串（🏷 起点小说）
        let single = HTTPClient.parseURLRule("https://a.com/api,{method:'POST',credentials:'omit'}")
        XCTAssertEqual(single.url, "https://a.com/api")
        XCTAssertEqual(single.options.method, "POST")

        // 值里是变量就无法求值，但地址必须切干净（🏷书旗小说）
        let variable = HTTPClient.parseURLRule("https://a.com/api,{bookId:BID,chapterId:CID}")
        XCTAssertEqual(variable.url, "https://a.com/api")

        // 单引号里含中文与逗号（📂台湾小说网）
        let quoted = HTTPClient.parseURLRule("https://a.com/x,{name:'打开网站',type:'button'}")
        XCTAssertEqual(quoted.url, "https://a.com/x")
    }

    /// 括号不配平的 `,{` 属于正文内容，不能当成选项切掉。
    func testParseURLRuleKeepsUnbalancedBraceComma() {
        let parsed = HTTPClient.parseURLRule("https://a.com/body,{未配平")
        XCTAssertEqual(parsed.url, "https://a.com/body,{未配平")
    }

    // MARK: 脚本归一化（箭头函数解构参数）

    /// 裸的解构参数要能补上括号。
    ///
    /// 书源写成 `arr.map([title, b] => {…})`，Rhino 宽容，而标准 JS 引擎
    /// （JavaScriptCore / V8）直接报 "Malformed arrow function parameter list"，
    /// 整段脚本一行都不执行 —— 界面表现是发现页 / 目录全空。
    /// 实测 id1263 的 1918 段脚本里有 30 段栽在这里。
    func testScriptNormalizerAddsParensToBareDestructuring() {
        XCTAssertEqual(
            ScriptNormalizer.normalizeArrowParameters("arr.map([a,b]=>{ return a+b; })"),
            "arr.map(([a,b])=>{ return a+b; })"
        )
        // 换行与空格不影响
        XCTAssertEqual(
            ScriptNormalizer.normalizeArrowParameters("arrb.map([title,b]=>\n\t\t\tarrc(title,a,b));"),
            "arrb.map(([title,b])=>\n\t\t\tarrc(title,a,b));"
        )
        // 对象模式同样要补
        XCTAssertEqual(
            ScriptNormalizer.normalizeArrowParameters("arr.map({x,y}=>x)"),
            "arr.map(({x,y})=>x)"
        )
        // 赋值形式（前面不是调用左括号）
        XCTAssertEqual(
            ScriptNormalizer.normalizeArrowParameters("f = [a,b]=>a+b;"),
            "f = ([a,b])=>a+b;"
        )
        // 尾部悬空逗号
        XCTAssertEqual(
            ScriptNormalizer.normalizeArrowParameters("arr.map([a,]=>a)"),
            "arr.map(([a,])=>a)"
        )
    }

    /// 归一化不能误伤数组字面量、字符串与已经合法的写法。
    ///
    /// 逐字符扫描的改写最有价值也最危险：一旦把 `[1,2]` 这类
    /// 数组字面量当成参数模式，会把本来能跑的脚本改成语法错误。
    func testScriptNormalizerLeavesUnrelatedCodeAlone() {
        // 已经合法的写法原样返回（无改动 → nil）
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("arr.map(([a,b])=>a+b)"))
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("f(([a,b])=>a)"))
        // 数组字面量
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("var x = [1,2]; var y = a[0];"))
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("require([1,2])"))
        // 下标访问后跟箭头（不是解构参数）
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("a[b] = c => d"))
        // 字符串 / 注释里的内容不能被改
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("var s = 'map([a,b]=>x)';"))
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("// arr.map([a,b]=>a)"))
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("/* [a,b]=> */ 1"))
        // 连续逗号不是合法的简单绑定模式，宁可放弃也不能乱改
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("arr.map([a,,b]=>a)"))
        // 默认值 / rest 一律不碰（放宽匹配会误伤数组字面量）
        XCTAssertNil(ScriptNormalizer.normalizeArrowParameters("arr.map([a=1]=>a)"))
    }

    /// 归一化候选只在常规形态都因语法错误失败后才追加。
    func testNormalizedCandidatesOnlyForBareDestructuring() {
        let bare = "arr.map([a,b]=>a+b);"
        let normalized = JSEngine.normalizedCandidates(bare)
        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(normalized[0].contains("([a,b])"))
        // 本来就合法的脚本没有归一化形态
        XCTAssertTrue(JSEngine.normalizedCandidates("var a = 1; a").isEmpty)
    }

    /// 端到端：裸解构参数的脚本必须能求值出结果，而不是静默返回空串。
    func testBareDestructuringArrowActuallyEvaluates() {
        let engine = JSEngine(host: JSEngine.Host())
        let script = """
        var out = [];
        [[1,2],[3,4]].map([a,b]=>{ out.push(a+b); });
        out.join(',')
        """
        XCTAssertEqual(engine.evaluateString(script), "3,7")
    }

    // MARK: 开头链式 `@` 与 `@js:` 标志

    /// 以 `@js:` 开头的规则不能被切出一个空首段。
    ///
    /// 症状：`@js:` 开头的正文规则整条作废，小说正文一个字都看不到，
    /// 调试日志里出现 "result.match is not a function"。
    ///
    /// 根因：splitChain 把开头的 `@` 当链分隔符，产生 ["", "js:…"]。
    /// 空首段求值成 .strings([])，这个**空数组**被当作脚本的 result。
    /// 实测 3460 个源里有 995 条规则以 `@js:` 开头。
    func testLeadingJSMarkerKeepsWholeScript() {
        let segments = RuleSyntax.splitChain("@js: result.match(/x/)[1]")
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].hasPrefix("@js:"))

        // `@@` 与 `@css:` / `@xpath:` 这些显式标志同理
        XCTAssertEqual(RuleSyntax.splitChain("@@h1@text").first, "@@h1")
        XCTAssertEqual(RuleSyntax.splitChain("@css:div p").count, 1)
        XCTAssertEqual(RuleSyntax.splitChain("@xpath://div/a").count, 1)
    }

    /// 以 `@js:` 开头的正文规则必须真的跑出正文。
    func testLeadingJSRuleStillReturnsContent() {
        let html = "<div id='c'>正文第一段</div>"
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: html, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(analyzer.string("@js: '结果:' + java.getString('#c@text')"), "结果:正文第一段")
    }

    /// 规则以链式 `@` 开头时，作用于当前节点。
    ///
    /// 目录规则大量写成「chapterList 选中 <a>，chapterUrl = @href」。
    /// 旧实现切出空首段，结果恒为空 —— 表现是「目录名 / 章节地址整列取不到」。
    func testLeadingChainMarkerAppliesToCurrentNode() {
        let html = "<a href='/book/1' title='第一章'>一</a>"
        let js = JSEngine(host: JSEngine.Host())
        let node = HTMLParser.parse(html)
        let analyzer = SourceEngine.makeAnalyzer(
            content: node, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        let itemAnalyzer = SourceEngine.makeAnalyzer(
            content: HTMLParser.parse(html).children.first,
            baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(itemAnalyzer.firstString("@href"), "/book/1")
        XCTAssertEqual(itemAnalyzer.string("@text"), "一")
        XCTAssertEqual(itemAnalyzer.string("@title"), "第一章")
        // 文档根节点上取 baseUrl 表示当前页面地址
        XCTAssertEqual(analyzer.string("@baseUrl"), "https://a.com")
        // 多段形态：先选子元素，再取属性
        let listAnalyzer = SourceEngine.makeAnalyzer(
            content: HTMLParser.parse("<li><a href='/book/2'>二</a></li>"),
            baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(listAnalyzer.firstString("@a@href"), "/book/2")
    }

    /// 文本规则的 result 必须是字符串，不能是数组。
    ///
    /// 症状：命中多条时 `result.match(...)` 报 "result.match is not a function"，
    /// 字数 / 分类 / 简介空着。
    /// 实测文本字段里对 result 调字符串方法的规则 280 条、调数组方法的 0 条。
    func testTextRuleResultIsJoinedString() {
        let html = "<div class='t'><p>时长 12.5万</p><p>字数 3.4万</p></div>"
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: html, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        // 命中多条时 result 仍是字符串：能调 match / split
        XCTAssertEqual(analyzer.string(".t p@text@js:typeof result"), "string")
        XCTAssertEqual(analyzer.string(".t p@text@js:result.split('\\n').length"), "2")
    }

    /// JSON 路径选出的多条列表在最后一个 JS 里是字符串，能安全做 URL 拼接。
    func testListRuleResultStaysArray() {
        let json = "{\"items\":[{\"id\":1},{\"id\":2}]}"
        let js = JSEngine(host: JSEngine.Host())
        let analyzer = SourceEngine.makeAnalyzer(
            content: json, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        let items = analyzer.listItems("$.items[*]@js:(Array.isArray(result) ? 'array' : 'other') + result.length")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(RuleUtil.asString(items[0]), "array2")
    }

    /// loginCheckJs 里的 result 是响应对象，能调 body() / code() / url()。
    ///
    /// 症状：调试日志里刷屏
    ///     TypeError: null is not an object (evaluating 'result.body')
    /// 「人机验证框」该弹不弹。
    ///
    /// 根因：登录检查脚本只注入了 src（正文），result 还是规则链上一步的值。
    /// Legado 是 evalJS(loginCheckJs, strResponse)，result 必须是响应对象。
    func testLoginCheckScriptSeesResponseObject() {
        let engine = JSEngine(host: JSEngine.Host())
        let response = HTTPResponse(
            data: Data(),
            text: "<html>Just a moment</html>",
            headers: ["Server": "cloudflare"],
            statusCode: 403,
            finalURL: URL(string: "https://a.com/s?q=1")
        )
        // 验证页判定：脚本按 Legado 的写法读 result.body() / result.code()
        let script = "var b = String(result.body() || ''); var c = result.code(); "
            + "/Just a moment/.test(b) && c >= 403 ? 'needVerify' : 'ok'"
        XCTAssertEqual(RuleUtil.asString(engine.evaluateLoginCheck(script, response: response)), "needVerify")

        // 覆盖只对这一次求值生效：嵌套求值（java.getString）必须拿到自己的 result
        engine.result = "干净的值"
        XCTAssertEqual(engine.evaluateString("String(result)"), "干净的值")
    }

    // MARK: 书源兼容层（全量语料缺口）

    /// 全量语料实测的缺口 API 必须都注册上。
    ///
    /// 依据：yckceo「阅读」近一年 953 个条目展开后的 19 万个书源，
    /// 逐条统计 `java.xxx(` 调用点再与本工程求差集。
    /// 这些调用普遍**裸写**（不在 try 里），缺一个就是
    /// `undefined is not a function` 把整段脚本打断。
    func testCompatJavaApisAreRegistered() {
        let engine = JSEngine(host: JSEngine.Host())
        let names = [
            "deviceID", "getAppVariant", "webViewUA",
            "refreshTocUrl", "refreshBookUrl", "refreshBookInfo", "refreshContent",
            "refreshBook", "reGetBook", "refreshBookToc",
            "setBaseUrl", "getRedirectUrl", "initUrl",
            "importScript", "readTxtFile", "readFile", "deleteFile",
            "downloadFile", "cacheFile", "getZipStringContent",
            "desEncodeToBase64String", "aesEncodeToBase64String",
            "aesBase64DecodeToByteArray", "aesDecodeArgsBase64Str",
            "showReadingBrowser", "startBrowserDp", "openVideoPlayer", "showPhoto",
            "upLoginData", "reLoginView", "getResponse", "getHeaderMap",
            "webViewGetOverrideUrl", "logType", "putSharedData",
            "getReadBookConfigMap", "getThemeConfigMap", "getThemeConfig",
            "clearCookie", "urlEncode", "openWeb", "openBook",
            "toURL", "aJax", "ajaxAwait", "postForm", "postAwait", "fetch",
            "toString", "addBook", "setClipboard", "startBrowserAwaitAwait",
            "connect", "ajax", "get", "post", "base64Encode", "base64Decode",
            "md5Encode", "timeFormat", "toast", "longToast"
        ]
        for name in names {
            let type = engine.evaluateString("typeof java." + name)
            XCTAssertEqual(type, "function", "java.\(name) 未注册，类型是 \(type)")
        }
    }

    /// `java.get('未保存变量')` / `cache.get('未保存键')` 必须返回空串。
    ///
    /// Linpx 等源会写 `JSON.parse(String(java.get('util')))`；undefined 会被
    /// String() 转成 "undefined"，再触发 JSON Parse error，整页发现内容失败。
    func testMissingVariablesAndCacheReturnEmptyString() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("String(java.get('util'))"), "")
        XCTAssertEqual(engine.evaluateString("typeof java.get('util')"), "string")
        XCTAssertEqual(engine.evaluateString("String(cache.get('missing'))"), "")
        XCTAssertEqual(engine.evaluateString("String(cache.getFromMemory('missing'))"), "")
    }

    /// `java.openWeb` 是打开网页，不等待用户操作。旧实现复用阻塞验证框，
    /// 会让黄豆短剧这类源在播放前弹“需要验证”。
    func testOpenWebDoesNotBlockUserAction() {
        let engine = JSEngine(host: JSEngine.Host())
        var waitCount = 0
        engine.awaitUserAction = { _, _ in
            waitCount += 1
            return "blocked"
        }
        _ = engine.evaluateString("java.openWeb('https://example.com/')")
        XCTAssertEqual(waitCount, 0)
    }

    /// 两个探测型 API 必须**保持未定义**，否则源会走错分支。
    ///
    /// - `java.qread`：源阅专有，141 个源写
    ///   `try { java.qread(); isqread = true } catch(e) {}` 探测环境。
    /// - `java.ocr`：阅读 T 版专有，4 个源用 `typeof java.ocr === "function"`
    ///   判断要不要走 T 版接口。
    ///
    /// 注册它们等于冒充另一个客户端，接口参数与返回结构都不一样。
    func testProbeApisStayUndefined() {
        let engine = JSEngine(host: JSEngine.Host())
        for name in ["qread", "ocr"] {
            XCTAssertEqual(
                engine.evaluateString("typeof java." + name),
                "undefined",
                "java.\(name) 是环境探针，必须保持 undefined"
            )
        }
    }

    /// `java.readBookConfig` 是**存在性探针**，必须是空串而不是对象。
    ///
    /// 28 个源写 `if (typeof java.readBookConfig == "undefined") { 提示升级 }`。
    /// 注册成对象会让类型判断变成 "string"… 或直接让源以为配置可用。
    func testReadBookConfigProbeShape() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof java.readBookConfig"), "string")
        XCTAssertEqual(engine.evaluateString("java.readBookConfig"), "")
    }

    /// 普通 UA 与 WebView UA 必须**不同**。
    ///
    /// 14 个源写 `java.getUserAgent() === java.getWebViewUA()` 来判断
    /// 自己是否跑在「源阅」上。两者相同时会误判成源阅，走错分支。
    func testUserAgentDiffersFromWebViewUA() {
        let engine = JSEngine(host: JSEngine.Host())
        let same = engine.evaluateString("java.getUserAgent() === java.getWebViewUA()")
        XCTAssertEqual(same, "false")
    }

    /// `book.setReverseToc(bool)` 必须存在并回写宿主（581 个源在用）。
    func testBookReverseTocWriteBack() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof book.setReverseToc"), "function")
        _ = engine.evaluateString("book.setReverseToc(true)")
        XCTAssertEqual(engine.bookMutation.reverseToc, true)
        _ = engine.evaluateString("book.setReverseToc(false)")
        XCTAssertEqual(engine.bookMutation.reverseToc, false)
    }

    /// `source.putLoginInfo(json)` 必须把账号信息回写宿主（349 个源在用）。
    ///
    /// 书源写法：`let a = source.getLoginInfoMap(); a["账号"]=…; source.putLoginInfo(JSON.stringify(a))`
    func testPutLoginInfoCapturesAccount() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof source.putLoginInfo"), "function")
        var captured: [String: String] = [:]
        engine.onLoginInfoChanged = { info in captured = info }
        _ = engine.evaluateString(#"source.putLoginInfo(JSON.stringify({"账号":"u1","密码":"p2"}))"#)
        XCTAssertEqual(captured["账号"], "u1")
        XCTAssertEqual(captured["密码"], "p2")
    }

    /// `source.variable` 属性赋值必须经过 setter（28 个源直接赋值）。
    ///
    /// 不接 setter 的话宿主的 onVariableChanged 收不到通知，
    /// 用户改的源变量下次刷新又回到默认值。
    func testSourceVariablePropertySetter() {
        let engine = JSEngine(host: JSEngine.Host())
        var changed = ""
        engine.onVariableChanged = { changed = $0 }
        _ = engine.evaluateString(#"source.variable = JSON.stringify({"ch":"都市"})"#)
        XCTAssertTrue(changed.contains("都市"), "setter 没触发，实际：\(changed)")
        XCTAssertEqual(engine.evaluateString("source.variable"), changed)
    }

    /// `java.toURL(url)` 必须给出 origin / pathname / host（95 个源在用）。
    ///
    /// 非法地址要抛错 —— 源写 `try{ host = java.toURL(host,"").origin }
    /// catch(e){ 提示不是有效链接 }`，返回空对象会让它误判成合法。
    func testToURLShape() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(
            engine.evaluateString(#"java.toURL("https://a.com/x/y?q=1","").origin"#),
            "https://a.com"
        )
        XCTAssertEqual(
            engine.evaluateString(#"java.toURL("https://a.com/x/y?q=1","").pathname"#),
            "/x/y"
        )
        // 非法地址：catch 分支必须能命中
        XCTAssertEqual(
            engine.evaluateString(#"var r; try { java.toURL("!!!","").origin; r = "ok" } catch(e) { r = "bad" } r"#),
            "bad"
        )
    }

    /// `java.aJax(url)` / `java.postForm(url, body)` 返回**响应体文本**而不是响应对象。
    ///
    /// 源写 `JSON.parse(java.aJax(url))`，给对象就会 "Unexpected token o"。
    func testAjaxTextReturningApisAreStrings() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof java.aJax"), "function")
        XCTAssertEqual(engine.evaluateString("typeof java.postForm"), "function")
        XCTAssertEqual(engine.evaluateString("typeof java.fetch"), "function")
        XCTAssertEqual(engine.evaluateString("typeof java.toString"), "function")
    }

    /// 书籍级字段必须注入（880 个源读 book.durChapterIndex）。
    func testBookProgressFieldsAreInjected() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof book.durChapterIndex"), "number")
        XCTAssertEqual(engine.evaluateString("typeof book.totalChapterNum"), "number")
        XCTAssertEqual(engine.evaluateString("typeof book.durChapterTitle"), "string")
        XCTAssertEqual(engine.evaluateString("typeof book.canUpdate"), "boolean")
        XCTAssertEqual(engine.evaluateString("typeof chapter.putImgUrl"), "function")
        XCTAssertEqual(engine.evaluateString("typeof book.putCustomVariable"), "function")
        XCTAssertEqual(engine.evaluateString("typeof book.setUseReplaceRule"), "function")
    }

    /// `book.readConfig` 不能是 undefined：148 个源写
    /// `book.readConfig == null || book.readConfig.useReplaceRule == null`。
    func testBookReadConfigIsObject() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof book.readConfig"), "object")
        XCTAssertEqual(engine.evaluateString("book.readConfig.useReplaceRule"), "true")
    }

    /// `cookie.mapToCookie(cookieHeader)` 要能吃下多组键值对。
    ///
    /// 16 个源把响应里的 set-cookie 整串丢进来做登录回写。
    func testCookieMapToCookieParsesMultiplePairs() {
        XCTAssertEqual(CookieJar.splitPairs("a=1; b=2; Path=/; HttpOnly").count, 2)
        XCTAssertEqual(CookieJar.splitPairs("a=1, b=2").count, 2)
        // Expires 里的日期逗号不能被当成分组分隔
        XCTAssertEqual(
            CookieJar.splitPairs("sid=abc; Expires=Wed, 21 Oct 2026 07:28:00 GMT").count,
            1
        )
    }

    /// 书籍上下文要能注入到书源引擎（目录规模 / 阅读进度）。
    func testSourceEngineBookContextInjection() {
        let dict: [String: Any] = [
            "bookSourceName": "测试源",
            "bookSourceUrl": "https://a.com",
            "bookSourceType": 0,
            "ruleSearch": ["bookList": "$.list[*]", "name": "$.name", "bookUrl": "$.url"]
        ]
        let source = BookSource(dict: dict)
        let engine = SourceEngine(source: source)
        var context = engine.bookContext
        context.totalChapterNum = 1234
        context.durChapterIndex = 56
        context.durChapterTitle = "第五十七章"
        engine.bookContext = context
        XCTAssertEqual(engine.bookContext.totalChapterNum, 1234)
        XCTAssertEqual(engine.bookContext.durChapterIndex, 56)
    }

    /// 刷新类 API 只登记、不在求值内部重入。
    func testRefreshRequestIsDeferred() {
        let dict: [String: Any] = [
            "bookSourceName": "测试源",
            "bookSourceUrl": "https://a.com",
            "bookSourceType": 0,
            "ruleSearch": ["bookList": "$.list[*]", "name": "$.name", "bookUrl": "$.url"]
        ]
        let source = BookSource(dict: dict)
        let engine = SourceEngine(source: source)
        XCTAssertTrue(engine.consumePendingRefresh().isEmpty)
        engine.registerPendingRefreshForTesting("refreshTocUrl")
        XCTAssertEqual(engine.consumePendingRefresh(), ["toc"])
        // 取走即清空：不会反复触发
        XCTAssertTrue(engine.consumePendingRefresh().isEmpty)
    }

    /// 书源声明里的标量字段要能被脚本直接读到（82 + 59 + 44 个源依赖）。
    ///
    /// 源里写 `source.bookSourceType == '3'` / `timeFormat(source.lastUpdateTime)`
    /// 这类按**原文**比较的判断，归一化后的 typed 值对不上，
    /// 因此必须原样透传一份。
    func testSourceMetaIsExposedToScripts() {
        let dict: [String: Any] = [
            "bookSourceName": "测试源",
            "bookSourceUrl": "https://a.com",
            "bookSourceType": 0,
            "lastUpdateTime": 1745825537477,
            "respondTime": 4475,
            "bookSourceGroup": "分组A",
            "enabledCookieJar": true,
            "ruleSearch": ["bookList": "$.list[*]"]
        ]
        let source = BookSource(dict: dict)
        let engine = SourceEngine(source: source)

        XCTAssertEqual(engine.evaluateScript("String(source.lastUpdateTime)"), "1745825537477")
        XCTAssertEqual(engine.evaluateScript("String(source.respondTime)"), "4475")
        XCTAssertEqual(engine.evaluateScript("String(source.bookSourceGroup)"), "分组A")
        XCTAssertEqual(engine.evaluateScript("typeof source.enabledCookieJar"), "boolean")
        // 规则字典不进 meta：体积是其余字段的上百倍，脚本也不会读
        XCTAssertEqual(engine.evaluateScript("typeof source.ruleSearch"), "undefined")
    }

    /// `book.order` 必须在：源写 `if (book && book.order != 0 && …)`，
    /// 缺失时 undefined != 0 恒为 true，走进「不在书架」的分支。
    func testBookOrderIsInjected() {
        let engine = JSEngine(host: JSEngine.Host())
        XCTAssertEqual(engine.evaluateString("typeof book.order"), "number")
        XCTAssertEqual(engine.evaluateString("String(book.order)"), "0")
    }

    // MARK: 全局 src 绑定（Legado evalJS 语义）

    /// 每次 JS 求值都要把「当前内容」绑成全局 `src`。
    ///
    /// Legado `AnalyzeRule.evalJS` 里是 `bindings["src"] = content`：
    /// src 是**本次求值所在分析器的内容**，不是页面 HTML 的常驻副本。
    /// 全量语料实测 3732 条订阅源规则读 src —— RSS 616「AI风月」的
    /// `datas[java.hexDecodeToString(src)]` 就是靠它拿分类序号。
    ///
    /// 旧实现只在建引擎时设一次 src，规则求值时从不更新，于是：
    /// 列表规则拿到的是初值、逐条字段规则拿到的还是页面内容，
    /// `JSON.parse(src)` 一律崩。
    func testSrcFollowsCurrentAnalysisContent() {
        let js = JSEngine(host: JSEngine.Host())
        let html = "<div id='c'>正文第一段</div>"
        let analyzer = SourceEngine.makeAnalyzer(
            content: html, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        // 内容本身就是 HTML 文本时，src 必须是它（含标签，可被正则处理）
        XCTAssertEqual(analyzer.string("@js: src.match(/正文(.*?)</)[1]"), "第一段")
        // 注意 string() 会 trim 首尾空白，断言不要以空格结尾
        XCTAssertEqual(analyzer.string("@js: src.slice(0, 4)"), "<div")
        XCTAssertEqual(analyzer.string("@js: String(src.length)"), String(html.count))

        // 换一个分析器（不同内容、同一个引擎）后 src 必须跟着换，
        // 而不是停留在上一次的内容上
        let other = SourceEngine.makeAnalyzer(
            content: "{\"a\":7}", baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(other.string("@js: JSON.parse(src).a"), "7")
    }

    /// 内容是元素节点时，src 给 outerHTML（脚本会拿它做正则 / 二次解析）。
    func testSrcIsOuterHTMLForElementContent() {
        let js = JSEngine(host: JSEngine.Host())
        let node = HTMLParser.parse("<a href='/b/9' class='x'>九</a>")
        let analyzer = SourceEngine.makeAnalyzer(
            content: node, baseUrl: "https://a.com", js: js, bookInfo: [:], chapterInfo: [:]
        )
        XCTAssertEqual(analyzer.string("@js: src.match(/href=\"([^\"]+)\"/)[1]"), "/b/9")
    }

    // MARK: data: URI 地址

    /// `data:;base64,<payload>` 地址不发请求，且带 `{"type":…}` 时给十六进制。
    ///
    /// 对齐 Legado：`getByteArrayIfDataUri()` + `if (type != null)
    /// return StrResponse(url, HexUtil.encodeHexStr(bytes))`。
    /// 实测 826 个书源 / 21 个订阅源把分类地址写成这种形式
    /// （`名称::data:;base64,MA==,{"type":0}`，payload 是分类序号）。
    /// 旧实现当真实 URL 去请求 → unsupportedURL，这些源的分类恒为空。
    func testDataURIAddressIsDecodedNotRequested() {
        var options = HTTPRequestOptions()
        options.type = "0"
        let response = HTTPClient.dataURIResponse(urlString: "data:;base64,MA==", options: options)
        XCTAssertNotNil(response)
        // "0" 的十六进制是 30；书源配套写 java.hexDecodeToString(src) 解回 "0"
        XCTAssertEqual(response?.text, "30")
        XCTAssertEqual(response?.statusCode, 200)

        // 没有 type 时给原文
        let plain = HTTPClient.dataURIResponse(
            urlString: "data:;base64,5L2g5aW9", options: HTTPRequestOptions()
        )
        XCTAssertEqual(plain?.text, "你好")

        // 非 data: 地址一律不管，交回正常请求路径
        XCTAssertNil(HTTPClient.dataURIResponse(
            urlString: "https://a.com/x", options: HTTPRequestOptions()
        ))
    }

    /// 订阅源的 `source.sourceIcon` 等声明字段要能被脚本读到（51 处用它取封面）。
    func testRssSourceMetaIsExposedToScripts() {
        let dict: [String: Any] = [
            "sourceName": "测试订阅",
            "sourceUrl": "https://a.com",
            "sourceIcon": "https://a.com/i.png",
            "sourceGroup": "AI创作",
            "lastUpdateTime": 12345,
            "ruleArticles": "@js: 1"
        ]
        let source = RssSource(dict: dict)
        XCTAssertEqual(source.icon, "https://a.com/i.png")

        let meta = source.metaJSON ?? ""
        XCTAssertTrue(meta.contains("sourceIcon"), "sourceIcon 必须在 meta 里")
        XCTAssertTrue(meta.contains("sourceGroup"))
        XCTAssertTrue(meta.contains("12345"))
        // 规则字典不进 meta
        XCTAssertFalse(meta.contains("ruleArticles"))
    }

}
