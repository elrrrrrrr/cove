import Foundation
import SwiftData

@Model
final class ReadingHistory {
    var id: UUID
    var title: String
    var url: String?              // web article URL or nil for local files
    var filePath: String?         // local or NAS path for files
    var fileType: FileType
    var progress: Double          // 0.0 – 1.0
    var lastReadAt: Date
    var thumbnailData: Data?         // small JPEG (local files / screenshots)
    var thumbnailURLString: String?  // remote URL — preferred for web video cards
    var definitionID: String?
    var nasConfigID: String?         // UUID string of the NASConfig used to open this file

    var thumbnailURL: URL? {
        thumbnailURLString.flatMap { URL(string: $0) }
    }

    /// Human-readable title: cleans up raw URLs / file paths stored as titles.
    var displayTitle: String { ReadingProjection.displayTitle(title) }

    init(
        title: String,
        url: String? = nil,
        filePath: String? = nil,
        fileType: FileType = .web,
        progress: Double = 0,
        thumbnailURLString: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.filePath = filePath
        self.fileType = fileType
        self.progress = progress
        self.lastReadAt = Date()
        self.thumbnailURLString = thumbnailURLString
    }
}

enum FileType: String, Codable, Sendable {
    case web
    case pdf
    case cbz
    case cbr
    case epub
    case txt
    case video
    case audio
    case image
    case comic
    case unknown

    var systemImage: String {
        switch self {
        case .web:     "globe"
        case .pdf:     "doc.richtext"
        case .cbz:     "photo.on.rectangle"
        case .cbr:     "photo.on.rectangle"
        case .epub:    "book"
        case .txt:     "doc.text"
        case .video:   "play.rectangle"
        case .audio:   "waveform"
        case .image:   "photo"
        case .comic:   "photo.on.rectangle.angled"
        case .unknown: "doc"
        }
    }
}
