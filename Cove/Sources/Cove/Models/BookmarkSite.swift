import Foundation
import SwiftData

@Model
final class BookmarkSite {
    var id: UUID
    var name: String
    var urlString: String         // 入口 URL（可以是子页面，如 /latest-updates/）
    var category: SiteCategory
    var faviconData: Data?
    var note: String              // 备注（可选）
    var createdAt: Date
    var sortOrder: Int
    var definitionID: String?
    var entryID: String?

    var url: URL? { URL(string: urlString) }

    init(
        name: String,
        urlString: String,
        category: SiteCategory = .other,
        note: String = "",
        sortOrder: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.urlString = urlString
        self.category = category
        self.note = note
        self.createdAt = Date()
        self.sortOrder = sortOrder
    }
}

enum SiteCategory: String, CaseIterable, Identifiable, Codable {
    case video   = "视频"
    case comic   = "漫画"
    case image   = "图片"
    case novel   = "小说"
    case news    = "新闻"
    case other   = "其他"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .video:  "play.rectangle.fill"
        case .comic:  "photo.on.rectangle.angled"
        case .image:  "photo.fill"
        case .novel:  "doc.text.fill"
        case .news:   "newspaper.fill"
        case .other:  "safari.fill"
        }
    }
}
