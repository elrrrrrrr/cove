import Foundation

/// Keeps the search destination separate from the category to return to.
struct SiteCatalogNavigation {
    let entryURLString: String
    private(set) var categoryURL: URL?
    private(set) var searchURL: URL?
    private(set) var keyword = ""

    var currentURL: URL? { searchURL ?? categoryURL ?? URL(string: entryURLString) }
    var categoryURLString: String { categoryURL?.absoluteString ?? entryURLString }

    mutating func selectCategory(_ url: URL) {
        categoryURL = url
        cancelSearch()
    }

    @discardableResult
    mutating func search(_ text: String, parser: SiteParser, base: URL?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = parser.searchURL(keyword: trimmed, base: base ?? currentURL) else { return false }
        keyword = trimmed
        searchURL = url
        return true
    }

    mutating func cancelSearch() {
        searchURL = nil
        keyword = ""
    }

    func parser(definitionID: String?, overrides: SiteParserOverrides? = nil) -> SiteParser {
        SiteParserRegistry.parser(for: currentURL?.absoluteString ?? entryURLString, definitionID: definitionID)
            .applying(overrides)
    }
}
