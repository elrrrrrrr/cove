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
    var addedAt: Date

    var pageURL: URL? { URL(string: pageURLString) }
    var thumbnailURL: URL? { thumbnailURLString.flatMap { URL(string: $0) } }

    init(title: String, pageURLString: String,
         thumbnailURLString: String? = nil,
         duration: String = "", siteName: String = "",
         isComic: Bool = false, definitionID: String? = nil) {
        self.id                 = UUID()
        self.title              = title
        self.pageURLString      = pageURLString
        self.thumbnailURLString = thumbnailURLString
        self.duration           = duration
        self.siteName           = siteName
        self.isComic            = isComic
        self.addedAt            = Date()
        self.definitionID       = definitionID
    }
}
