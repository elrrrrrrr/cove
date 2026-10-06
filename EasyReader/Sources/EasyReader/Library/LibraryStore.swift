import Foundation
import SwiftData
import Observation

@Model final class LibraryEntry {
    @Attribute(.unique) var id: String
    var resourceData: Data
    var isFavorite: Bool
    var lastOpenedAt: Date
    var progress: Double
    var position: Double
    var resumeLocator: String?
    var offlineRelativePath: String?
    init(item: ResourceItem) throws {
        id = item.id
        resourceData = try JSONEncoder().encode(item)
        isFavorite = false
        lastOpenedAt = .distantPast
        progress = 0
        position = 0
    }
    var resource: ResourceItem? { try? JSONDecoder().decode(ResourceItem.self, from: resourceData) }
}

@Observable @MainActor final class LibraryStore {
    private let context: ModelContext
    private let container: ModelContainer
    private(set) var entries: [LibraryEntry] = []
    private(set) var favorites: Set<String> = []
    private(set) var readIDs: Set<String> = []
    private(set) var favoriteItems: [ResourceItem] = []
    private(set) var recentItems: [ResourceItem] = []
    private(set) var offlineItems: [ResourceItem] = []
    private(set) var continuableItems: [ResourceItem] = []
    private(set) var progress: [String: Double] = [:]
    private var decoded: [String: ResourceItem] = [:]
    var error: String?

    init(context: ModelContext) {
        self.context = context
        self.container = context.container
        refresh()
    }
    func refresh() {
        do {
            entries = try context.fetch(FetchDescriptor<LibraryEntry>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]))
            decoded = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.resource.map { (entry.id, $0) } })
            rebuildIndexes()
        } catch { self.error = error.localizedDescription }
    }
    private func rebuildIndexes() {
        favorites = Set(entries.filter(\.isFavorite).map(\.id))
        readIDs = Set(entries.filter { $0.lastOpenedAt > .distantPast }.map(\.id))
        favoriteItems = entries.filter(\.isFavorite).compactMap { decoded[$0.id] }
        recentItems = entries.filter { $0.lastOpenedAt > .distantPast }.compactMap { decoded[$0.id] }
        continuableItems = entries.filter { ($0.progress > 0 && $0.progress < 1) || ($0.position > 0 && $0.progress < 1) }.compactMap { decoded[$0.id] }
        offlineItems = entries.filter { $0.offlineRelativePath != nil }.compactMap { decoded[$0.id] }
        progress = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.progress) })
    }
    func entry(for item: ResourceItem) throws -> LibraryEntry {
        if let value = entries.first(where: { $0.id == item.id }) { return value }
        let value = try LibraryEntry(item: item)
        context.insert(value)
        entries.append(value)
        decoded[item.id] = item
        return value
    }
    @discardableResult func opened(_ item: ResourceItem) throws -> LibraryEntry {
        let value = try entry(for: item)
        value.resourceData = try JSONEncoder().encode(item)
        decoded[item.id] = item
        value.lastOpenedAt = .now
        try persist()
        return value
    }
    func toggleFavorite(_ item: ResourceItem) throws {
        let value = try entry(for: item)
        value.isFavorite.toggle()
        try persist()
    }
    func persist() throws {
        do { try context.save(); entries.sort { $0.lastOpenedAt > $1.lastOpenedAt }; rebuildIndexes() }
        catch { context.rollback(); refresh(); throw error }
    }
    func importFavorites(_ data: Data) throws {
        let file = try JSONDecoder().decode(FavoriteFile.self, from: data)
        guard file.schemaVersion == 2 else { throw CoveError.message("收藏文件需要使用格式版本 2") }
        for item in file.items {
            guard !item.sourceID.isEmpty, !item.locator.isEmpty,
                  item.id == StableHash.of(item.sourceID + "\u{0}" + (item.identity ?? item.locator)) else {
                throw CoveError.message("收藏内容身份或地址无效")
            }
        }
        do {
            for item in file.items { try entry(for: item).isFavorite = true }
            try persist()
        } catch { context.rollback(); refresh(); throw error }
    }
    func exportFavorites() throws -> Data {
        let file = FavoriteFile(items: entries.filter(\.isFavorite).compactMap { decoded[$0.id] })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }
}

struct FavoriteFile: Codable {
    var schemaVersion = 2
    var items: [ResourceItem]
}
