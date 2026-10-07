import Foundation
import SwiftData

struct ConfigBackup: Codable {
    var schemaVersion = 1
    var exportDate: Date
    var settings: SettingsBackup
    var sites: [SiteBackup]
    var nasConfigs: [NASConfigBackup]
    var siteDefinitions: [SiteDefinition]
}

struct SettingsBackup: Codable {
    var readerFontSize: Double
    var readerTheme: String
    var contentBlockerEnabled: Bool
}

struct SiteBackup: Codable {
    var id: UUID
    var name: String
    var urlString: String
    var category: String
    var note: String
    var sortOrder: Int
    var parserConfig: SiteParserOverrides?
    var definitionID: String?
    var entryID: String?
}

struct NASConfigBackup: Codable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var shareName: String
}

extension ConfigBackup {
    @MainActor static func export(sites: [BookmarkSite], nasConfigs: [NASConfig],
                                 fontSize: Double, theme: ReaderTheme, blockerEnabled: Bool) -> ConfigBackup {
        ConfigBackup(exportDate: Date(),
            settings: SettingsBackup(readerFontSize: fontSize, readerTheme: theme.rawValue, contentBlockerEnabled: blockerEnabled),
            sites: sites.map { SiteBackup(id: $0.id, name: $0.name, urlString: $0.urlString, category: $0.category.rawValue,
                note: $0.note, sortOrder: $0.sortOrder, parserConfig: $0.parserOverrides, definitionID: $0.definitionID, entryID: $0.entryID) },
            nasConfigs: nasConfigs.map { NASConfigBackup(id: $0.id, name: $0.name, host: $0.host, port: $0.port,
                username: $0.username, shareName: $0.shareName) },
            siteDefinitions: SiteDefinitionStore.shared.definitions)
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw SiteDefinitionError.invalid("不支持的备份格式") }
        guard settings.readerFontSize.isFinite, (6...72).contains(settings.readerFontSize),
              ReaderTheme(rawValue: settings.readerTheme) != nil else { throw SiteDefinitionError.invalid("备份中的阅读设置无效") }
        for definition in siteDefinitions { try definition.validate() }
        guard Set(siteDefinitions.map(\.id)).count == siteDefinitions.count,
              Set(sites.map(\.id)).count == sites.count,
              Set(nasConfigs.map(\.id)).count == nasConfigs.count else { throw SiteDefinitionError.invalid("备份包含重复标识") }
        let definitionIDs = Set(siteDefinitions.map(\.id))
        for site in sites {
            guard let url = URL(string: site.urlString), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil,
                  SiteCategory(rawValue: site.category) != nil,
                  site.definitionID.map({ definitionIDs.contains($0) }) ?? true else { throw SiteDefinitionError.invalid("备份中的站点配置无效") }
        }
    }

    @MainActor func apply(to context: ModelContext) throws {
        try validate()
        let library = SiteDefinitionStore.shared
        let previousDefinitions = library.definitions
        try context.save()
        do {
            try library.replace(siteDefinitions)
            try context.delete(model: BookmarkSite.self)
            try context.delete(model: NASConfig.self)
            for value in sites {
                let site = BookmarkSite(name: value.name, urlString: value.urlString,
                    category: SiteCategory(rawValue: value.category) ?? .other, note: value.note, sortOrder: value.sortOrder)
                site.id = value.id; site.definitionID = value.definitionID; site.entryID = value.entryID
                site.parserOverrides = value.parserConfig
                context.insert(site)
            }
            for value in nasConfigs {
                let config = NASConfig(name: value.name, host: value.host, port: value.port, username: value.username, shareName: value.shareName)
                config.id = value.id
                context.insert(config)
            }
            try context.save()
        } catch {
            context.rollback()
            try? library.replace(previousDefinitions)
            throw error
        }
        UserDefaults.standard.set(settings.readerFontSize, forKey: "readerFontSize")
        UserDefaults.standard.set(settings.readerTheme, forKey: "readerTheme")
        UserDefaults.standard.set(settings.contentBlockerEnabled, forKey: "contentBlockerEnabled")
    }

    func writeToTempFile() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Cove-Backup.json")
        try encoder.encode(self).write(to: url, options: .atomic)
        return url
    }

    static func read(from url: URL) throws -> ConfigBackup {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(Self.self, from: Data(contentsOf: url))
        try result.validate()
        return result
    }
}
