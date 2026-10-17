import SwiftData
import Foundation

@MainActor enum ArticleReadingStore {
    static func history(for url: URL, in context: ModelContext) throws -> ReadingHistory? {
        let key = url.absoluteString
        let descriptor = FetchDescriptor<ReadingHistory>(predicate: #Predicate { $0.url == key }, sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)])
        return try context.fetch(descriptor).first { $0.fileType == .article }
    }

    @discardableResult static func save(item: ParsedItem, title: String, definitionID: String?, progress: Double,
                                       existing: ReadingHistory?, in context: ModelContext) throws -> ReadingHistory {
        let record: ReadingHistory
        if let existing { record = existing }
        else if let found = try history(for: item.pageURL, in: context) { record = found }
        else { record = ReadingHistory(title: title, url: item.pageURL.absoluteString, fileType: .article) }
        if record.modelContext == nil { context.insert(record) }
        record.title = title; record.definitionID = definitionID; record.thumbnailURLString = item.thumbnail?.absoluteString
        record.progress = progress.isFinite ? min(1, max(0, progress)) : 0
        record.lastReadAt = Date(); try context.save(); return record
    }

    static func favorite(for url: URL, in context: ModelContext) throws -> FavoriteVideo? {
        let key = url.absoluteString
        return try context.fetch(FetchDescriptor<FavoriteVideo>(predicate: #Predicate { $0.pageURLString == key })).first
    }

    static func captureSnapshot(for url: URL, document: ArticleDocument, replacing: Bool = false, in context: ModelContext) throws {
        guard let record = try favorite(for: url, in: context), record.isArticle,
              replacing || record.articleSnapshot == nil else { return }
        record.articleSnapshot = try document.snapshotData()
        try context.save()
    }

    @discardableResult static func toggleFavorite(item: ParsedItem, title: String, definitionID: String?, document: ArticleDocument? = nil, in context: ModelContext) throws -> Bool {
        if let existing = try favorite(for: item.pageURL, in: context) {
            context.delete(existing); try context.save(); return false
        }
        let value = FavoriteVideo(title: title, pageURLString: item.pageURL.absoluteString,
            thumbnailURLString: item.thumbnail?.absoluteString,
            siteName: SiteParserRegistry.definition(for: item.pageURL, id: definitionID)?.name ?? item.extra,
            isArticle: true, definitionID: definitionID)
        if let document = document ?? item.article { value.articleSnapshot = try document.snapshotData() }
        context.insert(value); try context.save(); return true
    }
}
