import XCTest
@testable import Cove

@MainActor final class SiteSearchTests: XCTestCase {
    private let base = URL(string: "https://mirror.example/books/?area=1&page=3")!
    private var definitions: [SiteDefinition] = []

    override func setUp() async throws {
        definitions = SiteParserRegistry.definitions
        var owner = SiteDefinition.starter(name: "漫画", url: base)
        owner.id = "example.search"
        owner.match = .init(hosts: ["origin.example"])
        owner.rules[0].contentType = "comic"
        owner.rules[0].searchURLTemplate = "/search?q={keyword}"
        owner.rules[0].pagination = .init(mode: "ajax", script: "return [];")
        owner.rules.append(.init(id: "search", role: "catalog", contentType: "comic", match: .init(pathPrefix: "/search"),
                                presentation: .init(layout: "list"), extract: .init(script: "return [];"),
                                pagination: .init(mode: "none"), searchURLTemplate: "/search?q={keyword}"))
        SiteParserRegistry.replaceDefinitions([owner])
    }
    override func tearDown() async throws { SiteParserRegistry.replaceDefinitions(definitions) }

    private func parser(_ template: String? = "/search?q={keyword}") -> SiteParser {
        SiteParser(hostPattern: "example", itemKind: .comic, waitSeconds: 0, extractItemsJS: "'[]'",
                   paginationMode: .none, searchURLTemplate: template)
    }
    private func query(_ keyword: String) throws -> URLComponents {
        let url = try XCTUnwrap(parser().searchURL(keyword: keyword, base: base))
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }
    func testChineseAndEmojiAreEncodedAsUTF8() throws {
        let value = try query("漫画🐋")
        XCTAssertEqual(value.queryItems?.first?.value, "漫画🐋")
        XCTAssertEqual(value.percentEncodedQuery, "q=%E6%BC%AB%E7%94%BB%F0%9F%90%8B")
    }
    func testReservedQueryCharactersStayInsideOneValue() throws {
        let value = try query("A&B=1#?+%")
        XCTAssertEqual(value.queryItems?.count, 1)
        XCTAssertEqual(value.queryItems?.first?.value, "A&B=1#?+%")
        XCTAssertNil(value.fragment)
    }
    func testSpacesAreNotTreatedAsPlusSigns() throws {
        let value = try query("A B+C")
        XCTAssertEqual(value.percentEncodedQuery, "q=A%20B%2BC")
    }
    func testAlreadyEscapedTextIsNotDecodedTwice() throws {
        XCTAssertEqual(try query("%26page%3D2").queryItems?.first?.value, "%26page%3D2")
    }
    func testPathSearchCannotEscapeItsPathSegment() throws {
        let url = try XCTUnwrap(parser("/tag/{keyword}/").searchURL(keyword: "a/b?c#d", base: base))
        XCTAssertTrue(url.absoluteString.hasSuffix("/tag/a%2Fb%3Fc%23d/"))
        XCTAssertNil(url.query); XCTAssertNil(url.fragment)
    }
    func testRelativeQuerySearchRetainsCurrentMirrorAndPath() throws {
        let url = try XCTUnwrap(parser("?q={keyword}&page=1").searchURL(keyword: "漫画", base: base))
        XCTAssertEqual(url.host(), base.host()); XCTAssertEqual(url.path, base.path)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "1")
    }
    func testAbsoluteTemplateRetainsItsConfiguredHost() throws {
        let url = try XCTUnwrap(parser("https://search.example/find?q={keyword}").searchURL(keyword: "a", base: base))
        XCTAssertEqual(url.host(), "search.example")
    }
    func testRootRelativeTemplateDropsCategoryFilters() throws {
        let url = try XCTUnwrap(parser().searchURL(keyword: "a", base: base))
        XCTAssertEqual(url.absoluteString, "https://mirror.example/search?q=a")
    }
    func testMissingTemplateDoesNotNavigate() {
        XCTAssertNil(parser(nil).searchURL(keyword: "a", base: base))
    }
    func testTemplateWithoutPlaceholderDoesNotNavigate() {
        XCTAssertNil(parser("/search").searchURL(keyword: "a", base: base))
    }
    func testNonWebSchemesAreRejected() {
        for template in ["javascript:{keyword}", "file:///tmp/{keyword}", "smb://host/{keyword}"] {
            XCTAssertNil(parser(template).searchURL(keyword: "a", base: base))
        }
    }
    func testRelativeTemplateRequiresABase() {
        XCTAssertNil(parser().searchURL(keyword: "a", base: nil))
    }
    func testSearchSelectsTargetRuleAndDisablesCategoryPagination() {
        var navigation = SiteCatalogNavigation(entryURLString: base.absoluteString)
        XCTAssertEqual(navigation.parser(definitionID: "example.search").paginationMode.typeString, "ajax")
        XCTAssertTrue(navigation.search("  漫画  ", parser: navigation.parser(definitionID: "example.search"), base: base))
        let result = navigation.parser(definitionID: "example.search")
        XCTAssertEqual(result.ruleID, "search"); XCTAssertEqual(result.itemKind, .comic)
        XCTAssertEqual(result.galleryLayout, .list); XCTAssertEqual(result.paginationMode.typeString, "none")
        XCTAssertEqual(navigation.keyword, "漫画")
    }
    func testCancelRestoresCategoryAndItsParserEvenAfterClearedText() {
        var navigation = SiteCatalogNavigation(entryURLString: "https://origin.example/books/")
        navigation.selectCategory(base)
        XCTAssertTrue(navigation.search("a", parser: parser(), base: base))
        navigation.cancelSearch()
        XCTAssertEqual(navigation.currentURL, base); XCTAssertEqual(navigation.keyword, "")
        XCTAssertEqual(navigation.parser(definitionID: "example.search").ruleID, "catalog")
        XCTAssertEqual(navigation.parser(definitionID: "example.search").paginationMode.typeString, "ajax")
    }
    func testConsecutiveSearchesReplaceTheKeyword() throws {
        var navigation = SiteCatalogNavigation(entryURLString: base.absoluteString)
        XCTAssertTrue(navigation.search("a", parser: parser(), base: base))
        XCTAssertTrue(navigation.search("b", parser: navigation.parser(definitionID: "example.search"), base: navigation.currentURL))
        XCTAssertEqual(navigation.keyword, "b")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(navigation.currentURL), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "b")
    }
    func testSelectingCategoryClearsSearchDestination() {
        var navigation = SiteCatalogNavigation(entryURLString: base.absoluteString)
        XCTAssertTrue(navigation.search("a", parser: parser(), base: base))
        navigation.selectCategory(base)
        XCTAssertNil(navigation.searchURL); XCTAssertEqual(navigation.currentURL, base)
    }
    func testBlankSubmissionLeavesExistingResultsUntouched() {
        var navigation = SiteCatalogNavigation(entryURLString: base.absoluteString)
        XCTAssertTrue(navigation.search("a", parser: parser(), base: base))
        let current = navigation.currentURL
        XCTAssertFalse(navigation.search(" \n ", parser: parser(), base: base))
        XCTAssertEqual(navigation.currentURL, current); XCTAssertEqual(navigation.keyword, "a")
    }
    func testUnsupportedSubmissionLeavesCategoryUntouched() {
        var navigation = SiteCatalogNavigation(entryURLString: base.absoluteString)
        XCTAssertFalse(navigation.search("a", parser: parser(nil), base: base))
        XCTAssertNil(navigation.searchURL); XCTAssertEqual(navigation.currentURL, base)
    }
    func testExplicitOwnerSurvivesMirrorHostChanges() {
        var navigation = SiteCatalogNavigation(entryURLString: base.absoluteString)
        XCTAssertTrue(navigation.search("a", parser: parser(), base: base))
        XCTAssertEqual(navigation.parser(definitionID: "example.search").definitionID, "example.search")
        XCTAssertNil(navigation.parser(definitionID: nil).definitionID)
    }
    func testRuleChangesApplyToCurrentSearchDestination() {
        var navigation = SiteCatalogNavigation(entryURLString: base.absoluteString)
        XCTAssertTrue(navigation.search("a", parser: parser(), base: base))
        var updated = SiteParserRegistry.definitions[0]
        updated.rules[1].presentation?.layout = "portrait"
        SiteParserRegistry.replaceDefinitions([updated])
        XCTAssertEqual(navigation.parser(definitionID: updated.id).galleryLayout, .portrait)
        XCTAssertEqual(navigation.parser(definitionID: updated.id).ruleID, "search")
    }
    func testBundledSearchTemplatesResolveToCatalogRules() throws {
        let bundled = SiteDefinitionStore.bundledDefinitions(bundle: Bundle(for: SiteDefinitionStore.self))
        XCTAssertTrue(bundled.issues.isEmpty)
        for owner in bundled.definitions {
            let base = try XCTUnwrap(owner.entries.first?.url(in: owner))
            for rule in owner.rules where rule.searchURLTemplate != nil {
                let parser = SiteParserRegistry.parser(definition: owner, rule: rule)
                let url = try XCTUnwrap(parser.searchURL(keyword: "漫画 A&B=1", base: base), "搜索模板无效：\(owner.id)/\(rule.id)")
                XCTAssertNotNil(owner.rule(for: url, role: "catalog"), "搜索地址没有列表规则：\(owner.id)/\(rule.id)")
            }
        }
    }
}
