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
        XCTAssertFalse(ReaderEntryPolicy.canOpenWithoutToc(
            type: .audio, tocUrl: nil, bookUrl: "https://a.com/audio/1"))
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

    /// HTMLNode 直接注入 JS 会在 JavaScriptCore 桥接层触发运行时陷阱。
    /// 净化后必须转成字符串，且求值本身不能崩。
    func testInjectingHTMLNodeIntoJSDoesNotCrash() {
        let engine = JSEngine(host: JSEngine.Host())
        let node = CSSSelector.select("div.item", in: document()).first ?? document()

        engine.result = node
        // 只要这里没崩，说明没把纯 Swift 对象交给 JavaScriptCore。
        let text = engine.evaluateString("typeof result")
        XCTAssertEqual(text, "string", "HTMLNode 必须先降级成字符串再注入 JS")
    }

    /// 含 HTMLNode 的容器同样要走净化路径（数组 / 字典 / 嵌套）。
    func testInjectingContainersWithHTMLNodeDoesNotCrash() {
        let engine = JSEngine(host: JSEngine.Host())
        let nodes = CSSSelector.select("div.item", in: document())
        XCTAssertFalse(nodes.isEmpty)

        engine.result = nodes
        XCTAssertEqual(engine.evaluateString("Array.isArray(result)"), "true")
        XCTAssertEqual(engine.evaluateString("typeof result[0]"), "string")

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
        XCTAssertEqual(engine.evaluateString("typeof result"), "string")
        XCTAssertEqual(engine.evaluateString("result.length > 0"), "true")
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

}
