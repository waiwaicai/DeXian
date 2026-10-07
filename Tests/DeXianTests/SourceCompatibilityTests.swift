import XCTest
@testable import DeXian

final class SourceCompatibilityTests: XCTestCase {
    func testPurifierRemovesCommonAdsAndPromotions() {
        let purifier = ContentPurifier(sourceRule: nil)
        let input = """
        正文开始。
        请收藏本站 https://ad.example.com
        本章未完，请点击下一页继续阅读
        最新章节请访问 www.site.top
        正文结束。
        """
        let output = purifier.purify(input)
        XCTAssertFalse(output.contains("请收藏本站"))
        XCTAssertFalse(output.contains("本章未完"))
        XCTAssertFalse(output.contains("www.site.top"))
        XCTAssertTrue(output.contains("正文开始"))
        XCTAssertTrue(output.contains("正文结束"))
    }

    func testPurifierSupportsUserRegexAndPlainTextRules() {
        let json = """
        [{"name":"去广告","pattern":"内部推广.*","replacement":""},
         {"name":"标点","find":"。。。","replace":"。"},
         "单独正则"]
        """
        let purifier = ContentPurifier(sourceRule: nil, userRulesJSON: json)
        let output = purifier.purify("正文。内部推广链接。。。单独正则文本")
        XCTAssertFalse(output.contains("内部推广"))
        XCTAssertFalse(output.contains("单独正则"))
        XCTAssertTrue(output.contains("正文。"))
        XCTAssertTrue(output.contains("文本"))
    }

    func testCleanContentUsesBuiltInPurifier() {
        let source = SourceImporter.makeSource([
            "bookSourceName": "净化源",
            "bookSourceUrl": "https://clean.test",
            "ruleContent": ["content": "body"]
        ])!
        let engine = SourceEngine(source: source)
        SettingsStore.shared = SettingsStore()
        let output = engine.cleanContent("正文。\n请记住本站域名 example.com\n结束。")
        XCTAssertTrue(output.contains("正文。"))
        XCTAssertFalse(output.contains("请记住本站域名"))
        XCTAssertTrue(output.contains("example.com"))
    }

    func testSourceProbeRecognizesShortContentAsInvalid() {
        let state = SourceProbe.State.invalid(reason: SourceCompatibility.describe(.contentTooShort(12)))
        XCTAssertTrue(state.isRemovable)
        XCTAssertEqual(state.displayText, "正文过短（12 字）")
    }

    func testInvalidShortContentReasonIsClearable() {
        XCTAssertTrue(SourceCompatibility.isRemovableReason("正文过短（8 字）"))
        XCTAssertFalse(SourceCompatibility.isRemovableReason("请求超时"))
    }
}
