import Foundation
import SwiftData

struct ConfigBackup: Codable {
    var schemaVersion = 1
    var exportDate: Date
    var settings: SettingsBackup
    var sites: [SiteBackup]
    var nasConfigs: [NASConfigBackup]
    var siteDefinitions: [SiteDefinition]
    var favorites: [FavoriteDataFile.FavoriteRecord]?
    var histories: [HistoryBackup]?
    var offlineItems: [OfflineBackup]?
    var preferences: [String: String]?
}

struct SettingsBackup: Codable {
    var readerFontSize: Double
    var readerTheme: String
    var contentBlockerEnabled: Bool
    var novelReadingMode: String?
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
    var createdAt: Date?
    var faviconData: Data?
}

struct NASConfigBackup: Codable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var shareName: String
    var isActive: Bool?
}

extension ConfigBackup {
    @MainActor static func export(sites: [BookmarkSite], nasConfigs: [NASConfig],
                                 fontSize: Double, theme: AppTheme, blockerEnabled: Bool, readingMode: NovelReadingMode = .paged) -> ConfigBackup {
        ConfigBackup(exportDate: Date(),
            settings: SettingsBackup(readerFontSize: fontSize, readerTheme: theme.rawValue, contentBlockerEnabled: blockerEnabled, novelReadingMode: readingMode.rawValue),
            sites: sites.map { SiteBackup(id: $0.id, name: $0.name, urlString: $0.urlString, category: $0.category.rawValue,
                note: $0.note, sortOrder: $0.sortOrder, parserConfig: $0.parserOverrides, definitionID: $0.definitionID, entryID: $0.entryID, createdAt: $0.createdAt, faviconData: $0.faviconData) },
            nasConfigs: nasConfigs.map { NASConfigBackup(id: $0.id, name: $0.name, host: $0.host, port: $0.port,
                username: $0.username, shareName: $0.shareName, isActive: $0.isActive) },
            siteDefinitions: SiteDefinitionStore.shared.definitions)
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw SiteDefinitionError.invalid("不支持的备份格式") }
        guard settings.readerFontSize.isFinite, (6...72).contains(settings.readerFontSize),
              AppTheme(rawValue: settings.readerTheme) != nil else { throw SiteDefinitionError.invalid("备份中的阅读设置无效") }
        if let mode = settings.novelReadingMode, NovelReadingMode(rawValue: mode) == nil {
            throw SiteDefinitionError.invalid("备份中的小说翻页方式无效")
        }
        if let favorites {
            guard favorites.allSatisfy({ $0.id != nil }) else { throw SiteDefinitionError.invalid("备份收藏缺少标识") }
            try FavoriteDataFile(favorites: favorites).validate()
        }
        if let histories {
            guard Set(histories.map(\.id)).count == histories.count,
                  histories.allSatisfy({ $0.progress.isFinite && $0.progress >= 0 && ($0.fileType == .web || ($0.fileType == .video && $0.url != nil) || $0.progress <= 1) }) else {
                throw SiteDefinitionError.invalid("阅读记录重复或进度无效")
            }
        }
        if let offlineItems {
            guard Set(offlineItems.map(\.id)).count == offlineItems.count, Set(offlineItems.map(\.localPath).filter { !$0.isEmpty }).count == offlineItems.filter { !$0.localPath.isEmpty }.count else { throw SiteDefinitionError.invalid("离线记录重复") }
            for item in offlineItems { try item.validate() }
        }
        for history in histories ?? [] {
            if let path = history.filePath, history.nasConfigID == nil, history.fileType != .comic {
                guard path.hasPrefix("Offline/"), !path.split(separator: "/").contains("..") else { throw SiteDefinitionError.invalid("阅读记录包含非便携路径") }
                _ = try ReaderContainedPath.resolve(path, under: LocalAppStorage.data)
            }
        }
        if let preferences { try SyncPreferences.validate(preferences) }
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
        try applySynchronized(to: context)
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
