import XCTest
@testable import Cove

@MainActor final class SiteFormModelTests: XCTestCase {
    private func fixture() throws -> SiteDefinition {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "demo", withExtension: "site", subdirectory: "Sites"))
        var value = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
        value.images = .init(hosts: ["images.example"], key: "1111111111111111", iv: "0000000000000000")
        value.portal = .init(url: "https://portal.example", dataPattern: "payload=(.+)", keyPattern: "key=(.+)", urlPaths: ["routes.*.url"], headers: ["Referer":"https://media.example/"])
        value.rules[0].load = .init(mode: "webView", waitSeconds: 0.125, preNavigateExpression: "document.querySelector('a')?.href", headers: ["Accept":"text/html"])
        value.rules[1].extract = .init(expression: "JSON.stringify({url:'https://stream.example/1.m3u8'})")
        return value
    }
    func testEditingOneFieldPreservesComplexSourceConfiguration() throws {
        let value = try fixture(), model = SiteFormModel()
        try model.load(value)
        model.set(.string("表单名称"), at: [.key("name")])
        var expected = value; expected.name = "表单名称"
        XCTAssertEqual(try model.definition(), expected)
        let source = try model.definition().yaml()
        let next = try SiteFormModel.sourceDraft(source)
        try model.load(next)
        XCTAssertEqual(try model.definition(), expected)
    }
    func testInvalidSourceRejectsUnknownKeysAndMalformedShapes() throws {
        let value = try fixture(), model = SiteFormModel(); try model.load(value)
        XCTAssertThrowsError(try SiteFormModel.sourceDraft(value.yaml() + "unknownOption: true\n"))
        XCTAssertThrowsError(try SiteFormModel.sourceDraft("rules: [\n"))
        XCTAssertEqual(try model.definition(), value)
        // A well-typed but incomplete edit is repairable in the form; saving still validates it.
        var incomplete = value; incomplete.name = ""
        try model.load(SiteFormModel.sourceDraft(incomplete.yaml()))
        XCTAssertThrowsError(try model.definition())
        model.set(.string("已修复"), at: [.key("name")])
        XCTAssertEqual(try model.definition().name, "已修复")
    }
    func testNumericTypingAndCollectionChangesKeepTheCorrectRule() throws {
        let value = try fixture(), model = SiteFormModel(); try model.load(value)
        let wait: SiteFormPath = [.key("rules"), .index(0), .key("load"), .key("waitSeconds")]
        model.setNumber("-", at: wait)
        XCTAssertThrowsError(try model.definition(validate: false))
        model.setNumber("0.", at: wait); model.setNumber("0.25", at: wait)
        XCTAssertEqual(try model.definition().rules[0].load?.waitSeconds, 0.25)
        model.reorder([1, 0] + Array(2..<value.rules.count), at: [.key("rules")])
        XCTAssertEqual(model.numericText(at: [.key("rules"), .index(1), .key("load"), .key("waitSeconds")]), "0.25")
        model.set(nil, at: [.key("rules"), .index(0)])
        XCTAssertEqual(try model.definition().rules[0].id, value.rules[0].id)
        XCTAssertEqual(model.numericText(at: wait), "0.25")
    }
    func testAddRemoveEntriesAndNestedFieldsRetainsExistingIdentity() throws {
        let value = try fixture(), model = SiteFormModel(); try model.load(value)
        model.append(SiteFormSpec.initial(.object("entry")), at: [.key("entries")])
        XCTAssertEqual(try model.definition().entries.prefix(2), value.entries[...])
        model.set(nil, at: [.key("entries"), .index(2)])
        let nested: SiteFormPath = [.key("rules"), .index(3), .key("extract"), .key("fields"), .key("chapters"), .key("fields"), .key("title"), .key("pattern")]
        model.set(.string("(.*)"), at: nested)
        let result = try model.definition()
        XCTAssertEqual(result.id, value.id)
        XCTAssertEqual(result.entries, value.entries)
        XCTAssertEqual(result.rules[3].extract?.fields?["chapters"]?.fields?["title"]?.pattern, "(.*)")
        XCTAssertEqual(result.images, value.images)
    }
}
