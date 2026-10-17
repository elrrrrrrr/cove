import Foundation
import SwiftData

/// Current favorites format shared by first-install import, export and folder synchronization.
struct FavoriteDataFile: Codable, Sendable {
    var schemaVersion: Int = 1
    var favorites: [FavoriteRecord]

    struct FavoriteRecord: Codable, Sendable {
        var id: UUID?
        var title: String
        var pageURL: String
        var thumbnail: String?
        var duration: String?
        var siteName: String?
        var isComic: Bool?
        var isArticle: Bool?
        var definitionID: String?
        var addedAt: Date?
        var isPinned: Bool?
        var pinOrder: Int?
        var articleSnapshot: Data? = nil
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw SiteDefinitionError.invalid("不支持的收藏数据版本") }
        let identifiers = favorites.compactMap(\.id)
        guard Set(identifiers).count == identifiers.count else { throw SiteDefinitionError.invalid("收藏 id 重复") }
        for record in favorites {
            guard let url = URL(string: record.pageURL), ["https", "http"].contains(url.scheme ?? ""),
                  url.host() != nil, !record.title.isEmpty else { throw SiteDefinitionError.invalid("收藏标题或地址无效：\(record.title)") }
            if let snapshot = record.articleSnapshot {
                guard record.isArticle == true else { throw SiteDefinitionError.invalid("仅图文收藏可保存正文") }
                _ = try ArticleDocument.decode(snapshot, base: url, fallbackTitle: record.title)
            }
            guard record.pinOrder.map({ $0 >= 0 }) ?? true else { throw SiteDefinitionError.invalid("收藏置顶顺序不能为负数") }
            guard !(record.isComic == true && record.isArticle == true) else { throw SiteDefinitionError.invalid("收藏不能同时是漫画和图文") }
        }
    }

    @MainActor func apply(to context: ModelContext) throws {
        try validate()
        let existing = try context.fetch(FetchDescriptor<FavoriteVideo>())
        var urls = Set(existing.map(\.pageURLString))
        var plannedURLs = urls
        var identifiers = Set(existing.map(\.id))
        for record in favorites where plannedURLs.insert(record.pageURL).inserted {
            if let id = record.id, !identifiers.insert(id).inserted { throw SiteDefinitionError.invalid("收藏 id 与已有记录冲突") }
        }
        var newPins: [(value: FavoriteVideo, position: Int)] = []
        for (position, record) in favorites.enumerated() where !urls.contains(record.pageURL) {
            let value = FavoriteVideo(title: record.title, pageURLString: record.pageURL,
                thumbnailURLString: record.thumbnail, duration: record.duration ?? "", siteName: record.siteName ?? "",
                isComic: record.isComic ?? false,
                isArticle: record.isArticle ?? false,
                definitionID: record.definitionID ?? URL(string: record.pageURL).flatMap { SiteParserRegistry.definition(for: $0)?.id })
            if let id = record.id { value.id = id }
            if let date = record.addedAt { value.addedAt = date }
            value.articleSnapshot = record.articleSnapshot
            value.isPinned = record.isPinned ?? false
            value.pinOrder = record.pinOrder ?? 0
            if value.isPinned { newPins.append((value, position)) }
            context.insert(value)
            urls.insert(record.pageURL)
        }
        if !newPins.isEmpty {
            newPins.sort {
                if $0.value.pinOrder != $1.value.pinOrder { return $0.value.pinOrder < $1.value.pinOrder }
                return $0.position < $1.position
            }
            let pins = FavoritePins.ordered(existing) + newPins.map(\.value)
            for (index, value) in pins.enumerated() { value.pinOrder = index }
        }
    }

    @MainActor static func export(_ values: [FavoriteVideo]) -> FavoriteDataFile {
        FavoriteDataFile(favorites: values.map {
            FavoriteRecord(id: $0.id, title: $0.title, pageURL: $0.pageURLString,
                thumbnail: $0.thumbnailURLString, duration: $0.duration, siteName: $0.siteName,
                isComic: $0.isComic, isArticle: $0.isArticle, definitionID: $0.definitionID, addedAt: $0.addedAt, isPinned: $0.isPinned, pinOrder: $0.pinOrder, articleSnapshot: $0.articleSnapshot)
        })
    }

    static func decode(_ bytes: Data) throws -> FavoriteDataFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: bytes)
        try value.validate()
        return value
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
