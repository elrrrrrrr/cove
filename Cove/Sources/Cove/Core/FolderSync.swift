import Foundation
import SwiftData

// MARK: - Portable Sync & Backup Payload (schemaVersion: 1, no passwords)

struct CoveSyncPayload: Codable, Sendable {
    var schemaVersion: Int = 1
    var exportedAt: Date = Date()
    var bookmarks: [Bookmark] = []
    var favorites: [Favorite] = []
    var histories: [History] = []
    var nasConfigs: [NAS] = []

    struct Bookmark: Codable, Sendable {
        var id: UUID; var name: String; var urlString: String; var category: SiteCategory
        var note: String; var createdAt: Date; var sortOrder: Int; var definitionID: String?; var entryID: String?
    }

    struct Favorite: Codable, Sendable {
        var id: UUID; var title: String; var pageURLString: String; var thumbnailURLString: String?
        var duration: String; var siteName: String; var definitionID: String?
        var isComic: Bool; var isArticle: Bool; var addedAt: Date; var isPinned: Bool; var pinOrder: Int
    }

    struct History: Codable, Sendable {
        var id: UUID; var title: String; var url: String?; var filePath: String?; var fileType: FileType
        var progress: Double; var lastReadAt: Date; var thumbnailURLString: String?
        var definitionID: String?; var nasConfigID: String?
    }

    struct NAS: Codable, Sendable {
        var id: UUID; var name: String; var host: String; var port: Int; var username: String; var shareName: String
    }

    static func encode(_ payload: Self) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        guard value.schemaVersion == 1 else {
            throw SiteDefinitionError.invalid("不支持的备份/同步格式版本：\(value.schemaVersion)")
        }
        return value
    }

    @MainActor static func snapshot(from context: ModelContext) throws -> Self {
        let bookmarks = try context.fetch(FetchDescriptor<BookmarkSite>()).map {
            Bookmark(id: $0.id, name: $0.name, urlString: $0.urlString, category: $0.category,
                     note: $0.note, createdAt: $0.createdAt, sortOrder: $0.sortOrder,
                     definitionID: $0.definitionID, entryID: $0.entryID)
        }
        let favorites = try context.fetch(FetchDescriptor<FavoriteVideo>()).map {
            Favorite(id: $0.id, title: $0.title, pageURLString: $0.pageURLString,
                     thumbnailURLString: $0.thumbnailURLString, duration: $0.duration,
                     siteName: $0.siteName, definitionID: $0.definitionID, isComic: $0.isComic,
                     isArticle: $0.isArticle, addedAt: $0.addedAt, isPinned: $0.isPinned, pinOrder: $0.pinOrder)
        }
        let histories = try context.fetch(FetchDescriptor<ReadingHistory>()).map {
            History(id: $0.id, title: $0.title, url: $0.url, filePath: $0.filePath,
                    fileType: $0.fileType, progress: $0.progress, lastReadAt: $0.lastReadAt,
                    thumbnailURLString: $0.thumbnailURLString, definitionID: $0.definitionID, nasConfigID: $0.nasConfigID)
        }
        let nas = try context.fetch(FetchDescriptor<NASConfig>()).map {
            NAS(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username, shareName: $0.shareName)
        }
        return Self(bookmarks: bookmarks, favorites: favorites, histories: histories, nasConfigs: nas)
    }

    @MainActor static func merge(_ remote: Self, into context: ModelContext) throws {
        // Bookmarks (match by id or definitionID+entryID or urlString)
        let localBookmarks = try context.fetch(FetchDescriptor<BookmarkSite>())
        for b in remote.bookmarks {
            guard WebURLSafety.resolveURL(b.urlString, relativeTo: nil) != nil else { continue }
            if let existing = localBookmarks.first(where: { $0.id == b.id })
                ?? (b.definitionID != nil && b.entryID != nil ? localBookmarks.first(where: { $0.definitionID == b.definitionID && $0.entryID == b.entryID }) : nil) {
                if b.createdAt > existing.createdAt {
                    existing.name = b.name; existing.urlString = b.urlString; existing.category = b.category
                    existing.note = b.note; existing.definitionID = b.definitionID; existing.entryID = b.entryID
                }
            } else {
                let inserted = BookmarkSite(name: b.name, urlString: b.urlString, category: b.category, note: b.note, sortOrder: b.sortOrder)
                inserted.id = b.id; inserted.createdAt = b.createdAt; inserted.definitionID = b.definitionID; inserted.entryID = b.entryID
                context.insert(inserted)
            }
        }

        // Favorites (match by pageURLString)
        let localFavorites = try context.fetch(FetchDescriptor<FavoriteVideo>())
        for f in remote.favorites {
            guard WebURLSafety.resolveURL(f.pageURLString, relativeTo: nil) != nil else { continue }
            if let existing = localFavorites.first(where: { $0.pageURLString == f.pageURLString }) {
                if f.addedAt > existing.addedAt {
                    existing.title = f.title; existing.thumbnailURLString = f.thumbnailURLString
                    existing.isPinned = f.isPinned; existing.pinOrder = f.pinOrder
                }
            } else {
                let inserted = FavoriteVideo(title: f.title, pageURLString: f.pageURLString, thumbnailURLString: f.thumbnailURLString,
                                             duration: f.duration, siteName: f.siteName, isComic: f.isComic, isArticle: f.isArticle, definitionID: f.definitionID)
                inserted.id = f.id; inserted.addedAt = f.addedAt; inserted.isPinned = f.isPinned; inserted.pinOrder = f.pinOrder
                context.insert(inserted)
            }
        }

        // History (LWW by lastReadAt, match by id or url or filePath)
        let localHistories = try context.fetch(FetchDescriptor<ReadingHistory>())
        for h in remote.histories {
            if let existing = localHistories.first(where: {
                $0.id == h.id || (h.url != nil && $0.url == h.url && $0.fileType == h.fileType)
                    || (h.filePath != nil && $0.filePath == h.filePath && $0.fileType == h.fileType && $0.nasConfigID == h.nasConfigID)
            }) {
                if h.lastReadAt > existing.lastReadAt {
                    existing.title = h.title; existing.progress = h.progress; existing.lastReadAt = h.lastReadAt
                    existing.thumbnailURLString = h.thumbnailURLString; existing.definitionID = h.definitionID
                }
            } else {
                let inserted = ReadingHistory(title: h.title, url: h.url, filePath: h.filePath, fileType: h.fileType,
                                              progress: h.progress, thumbnailURLString: h.thumbnailURLString)
                inserted.id = h.id; inserted.lastReadAt = h.lastReadAt
                inserted.definitionID = h.definitionID; inserted.nasConfigID = h.nasConfigID
                context.insert(inserted)
            }
        }

        // NAS configs (preserve UUIDs, never overwrite Keychain)
        let localNAS = try context.fetch(FetchDescriptor<NASConfig>())
        for n in remote.nasConfigs where !localNAS.contains(where: { $0.id == n.id }) {
            let inserted = NASConfig(name: n.name, host: n.host, port: n.port, username: n.username, shareName: n.shareName)
            inserted.id = n.id
            context.insert(inserted)
        }
        try context.save()
    }
}

// MARK: - SideStore-Compatible Folder Sync Manager

@Observable
@MainActor
final class FolderSyncManager {
    static let shared = FolderSyncManager()
    private static let bookmarkKey = "cove.folderSync.bookmark.v2"
    private static let lastSyncKey = "cove.folderSync.lastSync.v2"

    var folderName: String?
    var lastSyncAt: Date?
    var isSyncing = false
    var lastError: String?

    var isConnected: Bool { folderName != nil }

    init() {
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        folderName = resolvedFolder()?.lastPathComponent
    }

    func connect(folderURL: URL, context: ModelContext) async {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            folderName = folderURL.lastPathComponent
            lastError = nil
            await syncNow(context: context)
        } catch {
            lastError = "保存同步目录失败：\(error.localizedDescription)"
        }
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        folderName = nil; lastSyncAt = nil; lastError = nil
    }

    func syncNow(context: ModelContext) async {
        guard !isSyncing, let root = resolvedFolder() else { return }
        isSyncing = true; lastError = nil
        let accessed = root.startAccessingSecurityScopedResource()
        defer {
            if accessed { root.stopAccessingSecurityScopedResource() }
            isSyncing = false
        }
        do {
            // 1. Merge remote .site definitions
            let sitesDir = root.appendingPathComponent("sites", isDirectory: true)
            let remoteDefs = try coordinatedReadSites(in: sitesDir)
            for def in remoteDefs where SiteDefinitionStore.shared.definition(id: def.id) == nil {
                try SiteDefinitionStore.shared.importDefinition(def, context: context)
            }
            for def in SiteDefinitionStore.shared.definitions {
                let target = sitesDir.appendingPathComponent("\(def.id).site")
                if !FileManager.default.fileExists(atPath: target.path), let yaml = try? def.yaml().data(using: .utf8) {
                    try coordinatedWrite(yaml, to: target)
                }
            }

            // 2. Merge cove-state.json LWW and write back unified snapshot
            let stateFile = root.appendingPathComponent("cove-state.json")
            if let remoteData = try coordinatedRead(at: stateFile) {
                let remotePayload = try CoveSyncPayload.decode(remoteData)
                try CoveSyncPayload.merge(remotePayload, into: context)
            }
            let merged = try CoveSyncPayload.snapshot(from: context)
            try coordinatedWrite(CoveSyncPayload.encode(merged), to: stateFile)

            let now = Date()
            lastSyncAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolvedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    private func coordinatedRead(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var readError: NSError?; var result: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &readError) { target in
            result = try? Data(contentsOf: target)
        }
        if let readError { throw readError }
        return result
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var writeError: NSError?; var innerError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &writeError) { target in
            do { try data.write(to: target, options: .atomic) } catch { innerError = error }
        }
        if let err = writeError ?? innerError { throw err }
    }

    private func coordinatedReadSites(in dir: URL) throws -> [SiteDefinition] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "site" }
        return urls.compactMap { url in
            guard let data = try? coordinatedRead(at: url), let yaml = String(data: data, encoding: .utf8) else { return nil }
            return try? SiteDefinition.decode(yaml)
        }
    }
}
