import Foundation
import SwiftData

@Model
final class FavoriteVideo {
    var id: UUID
    var title: String
    var pageURLString: String
    var thumbnailURLString: String?
    var duration: String
    var siteName: String          // 来源站点显示名称
    var definitionID: String?
    var isComic: Bool = false     // true → route to ComicDetailView
    var isArticle: Bool = false
    @Attribute(.externalStorage) var articleSnapshot: Data?
    var addedAt: Date
    var isPinned: Bool = false
    var pinOrder: Int = 0

    var pageURL: URL? { URL(string: pageURLString) }
    var thumbnailURL: URL? { thumbnailURLString.flatMap { URL(string: $0) } }
    var contentKind: ItemKind { isArticle ? .article : (isComic ? .comic : .video) }
    var contentLabel: String { isArticle ? "图文" : (isComic ? "漫画" : "视频") }
    var contentIcon: String { isArticle ? "doc.text" : (isComic ? "photo.on.rectangle.angled" : "play.rectangle.fill") }

    init(title: String, pageURLString: String,
         thumbnailURLString: String? = nil,
         duration: String = "", siteName: String = "",
         isComic: Bool = false, isArticle: Bool = false, definitionID: String? = nil) {
        self.id                 = UUID()
        self.title              = title
        self.pageURLString      = pageURLString
        self.thumbnailURLString = thumbnailURLString
        self.duration           = duration
        self.siteName           = siteName
        self.isComic            = isComic
        self.isArticle          = isArticle
        self.addedAt            = Date()
        self.definitionID       = definitionID
    }
}

@MainActor enum FavoritePins {
    static func ordered(_ values: [FavoriteVideo]) -> [FavoriteVideo] {
        values.filter(\.isPinned).sorted {
            if $0.pinOrder != $1.pinOrder { return $0.pinOrder < $1.pinOrder }
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func set(_ favorite: FavoriteVideo, pinned: Bool, context: ModelContext) throws {
        guard favorite.isPinned != pinned else { return }
        try context.save()
        var values = ordered(try context.fetch(FetchDescriptor<FavoriteVideo>())).filter { $0.id != favorite.id }
        if pinned { values.append(favorite) }
        favorite.isPinned = pinned
        favorite.pinOrder = 0
        try persist(values, context: context)
    }

    static func reorder(_ values: [FavoriteVideo], context: ModelContext) throws {
        let current = ordered(try context.fetch(FetchDescriptor<FavoriteVideo>()))
        guard values.count == current.count, Set(values.map(\.id)) == Set(current.map(\.id)) else {
            throw SiteDefinitionError.invalid("请对完整的置顶列表排序")
        }
        try context.save()
        try persist(values, context: context)
    }

    private static func persist(_ values: [FavoriteVideo], context: ModelContext) throws {
        for (index, value) in values.enumerated() { value.pinOrder = index }
        do { try context.save() }
        catch { context.rollback(); throw error }
    }
}
