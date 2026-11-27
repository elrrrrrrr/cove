import Foundation
import SwiftData

// Additional records in the existing schemaVersion 1 configuration backup.
struct HistoryBackup: Codable {
    var id: UUID
    var title: String
    var url: String?
    var filePath: String?
    var fileType: FileType
    var progress: Double
    var lastReadAt: Date
    var thumbnailData: Data?
    var thumbnailURLString: String?
    var definitionID: String?
    var nasConfigID: String?
}

struct OfflineBackup: Codable {
    var id: UUID
    var title: String
    var sourceURL: String?
    var localPath: String
    var fileType: FileType
    var savedAt: Date
    var fileSizeBytes: Int64
    var thumbnailData: Data?
    var contentSHA256: String?

    func validate() throws {
        if fileType == .web && localPath.isEmpty && contentSHA256 == nil {
            guard let sourceURL, let url = URL(string: sourceURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw ReaderSafetyError.message("离线网页记录缺少有效地址")
            }
            return
        }
        let parts = localPath.split(separator: "/")
        guard localPath.hasPrefix("Offline/"), !parts.contains(".."), parts.dropFirst().contains(where: { $0 != "." }),
              fileSizeBytes >= 0 else { throw ReaderSafetyError.message("离线记录路径或大小无效") }
        _ = try ReaderContainedPath.resolve(localPath, under: LocalAppStorage.data)
        if let hash = contentSHA256 {
            guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ReaderSafetyError.message("离线文件校验值无效")
            }
        }
    }
}

enum SyncPreferences {
    static func accepts(_ key: String) -> Bool {
        key == "readerLineSpacing" || ["home.quickAccess.collapsed", "home.recent.collapsed", "home.offline.collapsed"].contains(key)
            || key.hasPrefix(BrowserLayout.preferencePrefix)
    }
    static func validate(_ values: [String: String]) throws {
        for (key, value) in values {
            guard accepts(key), key.count < 256 else { throw ReaderSafetyError.message("备份包含不支持的设置") }
            if key == "readerLineSpacing" {
                guard let number = Double(value), number.isFinite, (0...100).contains(number) else {
                    throw ReaderSafetyError.message("行间距无效")
                }
            } else if key.hasPrefix(BrowserLayout.preferencePrefix) {
                guard BrowserLayout(rawValue: value) != nil else { throw ReaderSafetyError.message("布局无效") }
            } else if value != "true" && value != "false" { throw ReaderSafetyError.message("折叠设置无效") }
        }
    }
    static func capture(_ defaults: UserDefaults) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where accepts(key) {
            if let text = value as? String { result[key] = text }
            else if key == "readerLineSpacing", let number = value as? NSNumber { result[key] = number.stringValue }
            else if let flag = value as? Bool { result[key] = flag ? "true" : "false" }
        }
        return result
    }
    static func apply(_ values: [String: String], to defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where accepts(key) && values[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values {
            if key == "readerLineSpacing" { defaults.set(Double(value), forKey: key) }
            else if key.hasPrefix(BrowserLayout.preferencePrefix) { defaults.set(value, forKey: key) }
            else { defaults.set(value == "true", forKey: key) }
        }
    }
}

extension ConfigBackup {
    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    static func decode(_ bytes: Data) throws -> ConfigBackup {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Self.self, from: bytes)
        try backup.validate()
        return backup
    }

    @MainActor static func captureAll(context: ModelContext) throws -> ConfigBackup {
        let defaults = UserDefaults.standard
        var result = export(sites: try context.fetch(FetchDescriptor<BookmarkSite>()),
            nasConfigs: try context.fetch(FetchDescriptor<NASConfig>()),
            fontSize: defaults.object(forKey: "readerFontSize") == nil ? 17 : defaults.double(forKey: "readerFontSize"),
            theme: AppTheme(rawValue: defaults.string(forKey: AppTheme.storageKey) ?? "") ?? .system,
            blockerEnabled: defaults.object(forKey: "contentBlockerEnabled") == nil || defaults.bool(forKey: "contentBlockerEnabled"),
            readingMode: NovelReadingMode(rawValue: defaults.string(forKey: NovelReadingMode.storageKey) ?? "") ?? .paged)
        result.favorites = FavoriteDataFile.export(try context.fetch(FetchDescriptor<FavoriteVideo>())).favorites
        result.histories = try context.fetch(FetchDescriptor<ReadingHistory>()).map { history in
            HistoryBackup(id: history.id, title: history.title, url: history.url,
                filePath: history.filePath.flatMap { path in
                    OfflineFiles.shared.normalizedPath(path) ?? (history.nasConfigID != nil || history.fileType == .comic ? path : nil)
                }, fileType: history.fileType, progress: history.progress.isFinite ? max(0, history.progress) : history.progress, lastReadAt: history.lastReadAt,
                thumbnailData: history.thumbnailData, thumbnailURLString: history.thumbnailURLString,
                definitionID: history.definitionID, nasConfigID: history.nasConfigID)
        }
        result.offlineItems = try context.fetch(FetchDescriptor<OfflineItem>()).map {
            guard let path = ($0.fileType == .web && $0.localPath.isEmpty ? "" : OfflineFiles.shared.normalizedPath($0.localPath)) else {
                throw ReaderSafetyError.message("有离线文件尚未迁移，暂不能同步")
            }
            return OfflineBackup(id: $0.id, title: $0.title, sourceURL: $0.sourceURL, localPath: path,
                fileType: $0.fileType, savedAt: $0.savedAt, fileSizeBytes: $0.fileSizeBytes,
                thumbnailData: $0.thumbnailData)
        }
        result.preferences = SyncPreferences.capture(defaults)
        try result.validate()
        return result
    }

    /// Reconcile in place: preserve SwiftData objects and UUIDs, never reseed deleted entries.
    @MainActor func applySynchronized(to context: ModelContext, store: SiteDefinitionStore = .shared) throws {
        try validate(); try context.save()
        let oldDefinitions = store.definitions
        var deletedOfflinePaths: [String] = []
        var keptOfflinePaths: Set<String> = []
        do {
            if store.definitions != siteDefinitions { try store.replace(siteDefinitions) }
            try reconcile(sites, existing: context.fetch(FetchDescriptor<BookmarkSite>()),
                existingID: \.id, recordID: \.id, context: context,
                make: { BookmarkSite(name: $0.name, urlString: $0.urlString) },
                update: { item, value in
                    item.name = value.name; item.urlString = value.urlString
                    item.category = SiteCategory(rawValue: value.category) ?? .other
                    item.note = value.note; item.sortOrder = value.sortOrder
                    item.definitionID = value.definitionID; item.entryID = value.entryID
                    if let date = value.createdAt { item.createdAt = date }; item.faviconData = value.faviconData
                })
            try reconcile(nasConfigs, existing: context.fetch(FetchDescriptor<NASConfig>()),
                existingID: \.id, recordID: \.id, context: context,
                make: { NASConfig(name: $0.name, host: $0.host, username: $0.username, shareName: $0.shareName) },
                update: { item, value in
                    item.name = value.name; item.host = value.host; item.port = value.port
                    item.username = value.username; item.shareName = value.shareName
                    if let active = value.isActive { item.isActive = active }
                })
            if let favorites {
                for value in favorites where value.id == nil { throw ReaderSafetyError.message("同步收藏缺少标识") }
                try reconcile(favorites, existing: context.fetch(FetchDescriptor<FavoriteVideo>()),
                    existingID: \.id, recordID: { $0.id! }, context: context,
                    make: { FavoriteVideo(title: $0.title, pageURLString: $0.pageURL) },
                    update: { item, value in
                        item.title = value.title; item.pageURLString = value.pageURL
                        item.thumbnailURLString = value.thumbnail; item.duration = value.duration ?? ""
                        item.siteName = value.siteName ?? ""; item.definitionID = value.definitionID
                        item.isComic = value.isComic ?? false; item.isArticle = value.isArticle ?? false; item.isPinned = value.isPinned ?? false
                        item.pinOrder = value.pinOrder ?? 0; if let date = value.addedAt { item.addedAt = date }
                    })
            }
            if let histories {
                try reconcile(histories, existing: context.fetch(FetchDescriptor<ReadingHistory>()),
                    existingID: \.id, recordID: \.id, context: context,
                    make: { ReadingHistory(title: $0.title) },
                    update: { item, value in
                        item.title = value.title; item.url = value.url
                        if let path = value.filePath {
                            // Portable backup paths rebase to this device's absolute reader URL.
                            if value.nasConfigID != nil || value.fileType == .comic { item.filePath = path }
                            else { item.filePath = OfflineFiles.shared.historyURL(for: path)?.path }
                        } else {
                            let external = item.nasConfigID == nil && item.fileType != .comic
                                && item.filePath?.hasPrefix("/") == true
                                && item.filePath.flatMap(OfflineFiles.shared.normalizedPath) == nil
                            if !external { item.filePath = nil }
                        }
                        item.fileType = value.fileType; item.progress = value.progress; item.lastReadAt = value.lastReadAt
                        item.thumbnailData = value.thumbnailData; item.thumbnailURLString = value.thumbnailURLString
                        item.definitionID = value.definitionID; item.nasConfigID = value.nasConfigID
                    })
            }
            if let offlineItems {
                let deleted = try reconcile(offlineItems, existing: context.fetch(FetchDescriptor<OfflineItem>()),
                    existingID: \.id, recordID: \.id, context: context,
                    make: { OfflineItem(title: $0.title, localPath: $0.localPath, fileType: $0.fileType) },
                    update: { item, value in
                        item.title = value.title; item.sourceURL = value.sourceURL; item.localPath = value.localPath
                        item.fileType = value.fileType; item.savedAt = value.savedAt
                        item.fileSizeBytes = value.fileSizeBytes; item.thumbnailData = value.thumbnailData
                    })
                deletedOfflinePaths = deleted.map(\.localPath)
                keptOfflinePaths = Set(offlineItems.map(\.localPath))
            }
            try context.save()
        } catch {
            context.rollback(); if store.definitions != oldDefinitions { try? store.replace(oldDefinitions) }; throw error
        }
        for path in deletedOfflinePaths where !path.isEmpty && !keptOfflinePaths.contains(path) {
            OfflineFiles.shared.deleteFile(path: path)
        }
        let defaults = UserDefaults.standard
        defaults.set(settings.readerFontSize, forKey: "readerFontSize")
        defaults.set(settings.readerTheme, forKey: AppTheme.storageKey)
        defaults.set(settings.novelReadingMode ?? NovelReadingMode.paged.rawValue, forKey: NovelReadingMode.storageKey)
        defaults.set(settings.contentBlockerEnabled, forKey: "contentBlockerEnabled")
        if let preferences { SyncPreferences.apply(preferences, to: defaults) }
    }

    @MainActor @discardableResult
    private func reconcile<Model: PersistentModel, Record>(
        _ records: [Record],
        existing: [Model],
        existingID: (Model) -> UUID,
        recordID: (Record) -> UUID,
        context: ModelContext,
        make: (Record) -> Model,
        update: (Model, Record) -> Void
    ) throws -> [Model] {
        let ids = Set(records.map(recordID))
        let byID = Dictionary(existing.map { (existingID($0), $0) }, uniquingKeysWith: { first, _ in first })
        var deleted: [Model] = []
        for item in existing where !ids.contains(existingID(item)) {
            deleted.append(item)
            context.delete(item)
        }
        for value in records {
            let id = recordID(value)
            let item = byID[id] ?? make(value)
            if item.modelContext == nil {
                if let site = item as? BookmarkSite { site.id = id }
                else if let nas = item as? NASConfig { nas.id = id }
                else if let fav = item as? FavoriteVideo { fav.id = id }
                else if let hist = item as? ReadingHistory { hist.id = id }
                else if let off = item as? OfflineItem { off.id = id }
                context.insert(item)
            }
            update(item, value)
        }
        return deleted
    }
}
