import Foundation
import SwiftData

struct ConfigBackup: Codable {
    var version: Int = 2
    var exportDate: Date
    var settings: SettingsBackup
    var sites: [SiteBackup]
    var nasConfigs: [NASConfigBackup]
    var siteDefinitions: [SiteDefinition]? = nil
}

struct SettingsBackup: Codable {
    var readerFontSize: Double
    var readerTheme: String
    var contentBlockerEnabled: Bool
}

struct SiteBackup: Codable {
    var name: String
    var urlString: String
    var category: String
    var note: String
    var sortOrder: Int
    // Legacy fields (kept for backward import compatibility)
    var customExtractJS: String?
    var customPreNavigateJS: String?
    // Full parser config override
    var parserConfig: SiteParserOverrides?
    var id: UUID? = nil
    var definitionID: String? = nil
    var entryID: String? = nil
}

struct NASConfigBackup: Codable {
    var name: String
    var host: String
    var port: Int
    var username: String
    var shareName: String
    var connectionType: String
    var quickConnectID: String?
    var fnConnectID: String?
    var id: UUID? = nil
}

// MARK: - Export

extension ConfigBackup {
    @MainActor static func export(
        sites: [BookmarkSite],
        nasConfigs: [NASConfig],
        fontSize: Double,
        theme: ReaderTheme,
        blockerEnabled: Bool
    ) -> ConfigBackup {
        ConfigBackup(
            exportDate: Date(),
            settings: SettingsBackup(
                readerFontSize: fontSize,
                readerTheme: theme.rawValue,
                contentBlockerEnabled: blockerEnabled
            ),
            sites: sites.map { site in
                SiteBackup(
                    name: site.name,
                    urlString: site.urlString,
                    category: site.category.rawValue,
                    note: site.note,
                    sortOrder: site.sortOrder,
                    parserConfig: site.parserOverrides,
                    id: site.id, definitionID: site.definitionID, entryID: site.entryID
                )
            },
            nasConfigs: nasConfigs.map { cfg in
                NASConfigBackup(
                    name: cfg.name,
                    host: cfg.host,
                    port: cfg.port,
                    username: cfg.username,
                    shareName: cfg.shareName,
                    connectionType: cfg.connectionType,
                    quickConnectID: cfg.quickConnectID,
                    fnConnectID: cfg.fnConnectID,
                    id: cfg.id
                )
            },
            siteDefinitions: SiteDefinitionStore.shared.definitions
        )
    }
}

// MARK: - Import

extension ConfigBackup {
    @MainActor func apply(to context: ModelContext) throws {
        guard (1...2).contains(version) else { throw SiteDefinitionError.invalid("不支持的备份版本") }
        if let definitions = siteDefinitions {
            for definition in definitions { try definition.validate() }
            guard Set(definitions.map(\.id)).count == definitions.count else { throw SiteDefinitionError.invalid("备份包含重复站点 id") }
            let ids = Set(definitions.map(\.id))
            guard sites.allSatisfy({ $0.definitionID == nil || ids.contains($0.definitionID!) }) else {
                throw SiteDefinitionError.invalid("备份中的书签引用了不存在的站点配置")
            }
        }
        for site in sites {
            guard let url = URL(string: site.urlString), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil else {
                throw SiteDefinitionError.invalid("备份中的站点地址无效")
            }
        }
        let library = SiteDefinitionStore.shared
        let previousDefinitions = library.definitions
        let previousNAS = try context.fetch(FetchDescriptor<NASConfig>())
        let matchedNASIDs = nasConfigs.map { value in
            value.id ?? previousNAS.first { $0.host == value.host && $0.port == value.port && $0.username == value.username && $0.shareName == value.shareName && $0.connectionType == value.connectionType && $0.quickConnectID == value.quickConnectID && $0.fnConnectID == value.fnConnectID }?.id
        }
        try context.save()
        do {
            if let definitions = siteDefinitions { try library.replace(definitions) }

        // Delete existing sites & NAS configs
        try context.delete(model: BookmarkSite.self)
        try context.delete(model: NASConfig.self)

        // Insert sites
        for (index, s) in sites.enumerated() {
            let site = BookmarkSite(
                name: s.name,
                urlString: s.urlString,
                category: SiteCategory(rawValue: s.category) ?? .other,
                note: s.note,
                sortOrder: s.sortOrder
            )
            if let id = s.id { site.id = id }
            site.definitionID = s.definitionID ?? URL(string: s.urlString).flatMap { SiteParserRegistry.definition(for: $0)?.id }
            site.entryID = s.entryID
            // Apply parser config: prefer new format, fall back to legacy fields
            if let config = s.parserConfig {
                site.parserOverrides = config
            } else if s.customExtractJS != nil || s.customPreNavigateJS != nil {
                var o = SiteParserOverrides()
                o.extractItemsJS = s.customExtractJS
                o.preNavigateJS = s.customPreNavigateJS
                site.parserOverrides = o
            }
            // Preserve original sort order; fallback to array index
            site.sortOrder = s.sortOrder != 0 ? s.sortOrder : index
            context.insert(site)
        }

        // Insert NAS configs
        for (index, n) in nasConfigs.enumerated() {
            let config = NASConfig(name: n.name, host: n.host, port: n.port, username: n.username, shareName: n.shareName)
            if let id = matchedNASIDs[index] { config.id = id }
            config.connectionType = n.connectionType
            config.quickConnectID = n.quickConnectID
            config.fnConnectID = n.fnConnectID
            context.insert(config)
        }

        try context.save()
        } catch {
            context.rollback()
            if siteDefinitions != nil { try? library.replace(previousDefinitions) }
            throw error
        }

        // Apply AppStorage settings
        UserDefaults.standard.set(settings.readerFontSize, forKey: "readerFontSize")
        if let theme = ReaderTheme(rawValue: settings.readerTheme) {
            UserDefaults.standard.set(theme.rawValue, forKey: "readerTheme")
        }
        UserDefaults.standard.set(settings.contentBlockerEnabled, forKey: "contentBlockerEnabled")
    }
}

// MARK: - JSON helpers

extension ConfigBackup {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func writeToTempFile() throws -> URL {
        let data = try Self.encoder.encode(self)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyReader-Backup.json")
        try data.write(to: tmp, options: .atomic)
        return tmp
    }

    static func read(from url: URL) throws -> ConfigBackup {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ConfigBackup.self, from: data)
    }
}
