import Foundation
import SwiftData

/// Optional local first-install data, supplied as data/favorites.json at build time.
struct FavoriteDataFile: Codable, Sendable {
    var version: Int
    var favorites: [FavoriteRecord]

    struct FavoriteRecord: Codable, Sendable {
        var id: UUID?
        var title: String
        var pageURL: String
        var thumbnail: String?
        var duration: String?
        var siteName: String?
        var isComic: Bool?
        var definitionID: String?
        var addedAt: Date?
    }

    func validate() throws {
        guard version == 1 else { throw SiteDefinitionError.invalid("不支持的收藏数据版本") }
        let identifiers = favorites.compactMap(\.id)
        guard Set(identifiers).count == identifiers.count else { throw SiteDefinitionError.invalid("收藏 id 重复") }
        for record in favorites {
            guard let url = URL(string: record.pageURL), ["https", "http"].contains(url.scheme ?? ""),
                  url.host() != nil, !record.title.isEmpty else { throw SiteDefinitionError.invalid("收藏标题或地址无效：\(record.title)") }
        }
    }

    @MainActor func apply(to context: ModelContext) throws {
        try validate()
        let existing = try context.fetch(FetchDescriptor<FavoriteVideo>())
        var urls = Set(existing.map(\.pageURLString))
        for record in favorites where !urls.contains(record.pageURL) {
            let value = FavoriteVideo(title: record.title, pageURLString: record.pageURL,
                thumbnailURLString: record.thumbnail, duration: record.duration ?? "", siteName: record.siteName ?? "",
                isComic: record.isComic ?? false,
                definitionID: record.definitionID ?? URL(string: record.pageURL).flatMap { SiteParserRegistry.definition(for: $0)?.id })
            if let id = record.id { value.id = id }
            if let date = record.addedAt { value.addedAt = date }
            context.insert(value)
            urls.insert(record.pageURL)
        }
    }

    @MainActor static func export(_ values: [FavoriteVideo]) -> FavoriteDataFile {
        FavoriteDataFile(version: 1, favorites: values.map {
            FavoriteRecord(id: $0.id, title: $0.title, pageURL: $0.pageURLString,
                thumbnail: $0.thumbnailURLString, duration: $0.duration, siteName: $0.siteName,
                isComic: $0.isComic, definitionID: $0.definitionID, addedAt: $0.addedAt)
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
