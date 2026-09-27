import XCTest
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

    @MainActor
    func testChapterCacheStoresAndReadsBack() {
        let cache = ChapterCache.shared
        let bookId = "test-cache-book-" + UUID().uuidString
        let chapterUrl = "https://comic.test/ch/" + UUID().uuidString
        defer { cache.remove(bookId: bookId) }

        XCTAssertFalse(cache.isCached(bookId: bookId, chapterUrl: chapterUrl))
        let content = ChapterContent(text: "缓存正文", images: [], nextChapterUrl: nil)
        cache.store(bookId: bookId, name: "缓存测试", origin: "src", chapterUrl: chapterUrl, content: content)

        XCTAssertTrue(cache.isCached(bookId: bookId, chapterUrl: chapterUrl))
        XCTAssertEqual(cache.content(bookId: bookId, chapterUrl: chapterUrl)?.text, "缓存正文")
        XCTAssertEqual(cache.counts(bookId: bookId).cached, 1)

        cache.remove(bookId: bookId)
        XCTAssertFalse(cache.isCached(bookId: bookId, chapterUrl: chapterUrl))
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
}
