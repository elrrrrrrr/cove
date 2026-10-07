import Foundation
import SwiftData

@Observable @MainActor
final class SiteDefinitionStore {
    static let shared = SiteDefinitionStore()
    private(set) var definitions: [SiteDefinition] = []
    var issues: [String] = []
    var pendingImport: SiteDefinition?
    private let storageURL: URL
    private var initialized = false
    static let bootstrapKey = "siteDefinitions.initialized.v1"
    static let pendingBootstrapKey = "siteDefinitions.initializingFresh.v1"

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? LocalAppStorage.config.appendingPathComponent("sites.json")
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do {
                definitions = try JSONDecoder().decode([SiteDefinition].self, from: Data(contentsOf: self.storageURL))
                for value in definitions { try value.validate() }
            } catch {
                definitions = []
                issues.append("读取站点配置失败：\(error.localizedDescription)")
            }
        }
        SiteParserRegistry.replaceDefinitions(definitions)
    }

    func save(_ definition: SiteDefinition) throws {
        try definition.validate()
        var values = definitions.filter { $0.id != definition.id }
        values.append(definition)
        try replace(values)
    }

    func replace(_ values: [SiteDefinition]) throws {
        for value in values { try value.validate() }
        guard Set(values.map(\.id)).count == values.count else { throw SiteDefinitionError.invalid("站点 id 重复") }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: storageURL, options: .atomic)
        definitions = values.sorted { $0.id < $1.id }
        SiteParserRegistry.replaceDefinitions(definitions)
    }

    func remove(id: String) throws { try replace(definitions.filter { $0.id != id }) }

    func definition(id: String?) -> SiteDefinition? {
        guard let id else { return nil }
        return definitions.first { $0.id == id }
    }

    static func bundledDefinitions(bundle: Bundle = .main) -> (definitions: [SiteDefinition], issues: [String]) {
        let urls = (bundle.urls(forResourcesWithExtension: "site", subdirectory: "Sites") ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var values: [SiteDefinition] = [], issues: [String] = []
        for url in urls {
            do {
                let definition = try SiteDefinition.decode(String(contentsOf: url, encoding: .utf8))
                guard !values.contains(where: { $0.id == definition.id }) else { throw SiteDefinitionError.invalid("站点 id 重复：\(definition.id)") }
                values.append(definition)
            } catch { issues.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return (values, issues)
    }

    /// A fresh installation imports once, including when the bundle contains no definitions.
    /// Upgrades only migrate existing bookmarks/referenced pages, never add new bundled entries.
    func initialize(context: ModelContext, freshInstall: Bool, defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        guard !initialized else { return }
        initialized = true
        guard !defaults.bool(forKey: Self.bootstrapKey) else { return }
        let importingFresh = freshInstall || defaults.bool(forKey: Self.pendingBootstrapKey)
        if importingFresh { defaults.set(true, forKey: Self.pendingBootstrapKey) }
        let previousDefinitions = definitions
        let bundled = Self.bundledDefinitions(bundle: bundle)
        issues.append(contentsOf: bundled.issues)
        do {
            if importingFresh {
                try replace(bundled.definitions)
                for definition in definitions { addEntries(definition, context: context) }
                if let url = bundle.url(forResource: "favorites", withExtension: "json", subdirectory: "BundledData") {
                    do { try FavoriteDataFile.decode(Data(contentsOf: url)).apply(to: context) }
                    catch { issues.append("favorites.json：\(error.localizedDescription)") }
                }
            } else {
                let bookmarks = try context.fetch(FetchDescriptor<BookmarkSite>())
                let favorites = try context.fetch(FetchDescriptor<FavoriteVideo>())
                let histories = try context.fetch(FetchDescriptor<ReadingHistory>())
                let references = bookmarks.map(\.urlString) + favorites.map(\.pageURLString) + histories.compactMap(\.url)
                var migrated = definitions
                for definition in bundled.definitions where !migrated.contains(where: { $0.id == definition.id }) {
                    if references.compactMap(URL.init(string:)).contains(where: { definition.match.matches($0) }) { migrated.append(definition) }
                }
                try replace(migrated)
                for favorite in favorites {
                    if let url = favorite.pageURL { favorite.definitionID = SiteParserRegistry.definition(for: url)?.id }
                }
                for history in histories {
                    if let raw = history.url, let url = URL(string: raw) { history.definitionID = SiteParserRegistry.definition(for: url)?.id }
                }
                for bookmark in bookmarks {
                    guard let url = bookmark.url, let definition = SiteParserRegistry.definition(for: url) else { continue }
                    bookmark.definitionID = definition.id
                    // Keep legacy user overrides until they are materialized by the editor.
                }
            }
            try context.save()
            defaults.set(true, forKey: Self.bootstrapKey)
            defaults.removeObject(forKey: Self.pendingBootstrapKey)
        } catch {
            context.rollback()
            try? replace(previousDefinitions)
            initialized = false
            issues.append("初始化站点配置失败：\(error.localizedDescription)")
        }
    }

    func addEntries(_ definition: SiteDefinition, context: ModelContext) {
        let bookmarks = (try? context.fetch(FetchDescriptor<BookmarkSite>())) ?? []
        var order = (bookmarks.map(\.sortOrder).max() ?? -1) + 1
        for entry in definition.entries {
            guard let url = entry.url(in: definition) else { continue }
            if let bookmark = bookmarks.first(where: { $0.definitionID == definition.id && $0.entryID == entry.id }) {
                bookmark.name = entry.name
                bookmark.urlString = url.absoluteString
                bookmark.category = SiteCategory(configurationValue: entry.category) ?? .other
                continue
            }
            let bookmark = BookmarkSite(name: entry.name, urlString: url.absoluteString,
                                        category: SiteCategory(configurationValue: entry.category) ?? .other,
                                        sortOrder: order)
            bookmark.definitionID = definition.id
            bookmark.entryID = entry.id
            context.insert(bookmark)
            order += 1
        }
    }

    func importDefinition(_ value: SiteDefinition, context: ModelContext, asCopy: Bool = false) throws {
        var definition = value
        if asCopy { definition.id = "user." + UUID().uuidString.lowercased(); definition.name += "（副本）" }
        let previous = definitions
        do {
            try save(definition)
            addEntries(definition, context: context)
            try context.save()
        } catch {
            context.rollback()
            try? replace(previous)
            throw error
        }
    }
}
