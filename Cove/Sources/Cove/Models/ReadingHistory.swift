import Foundation
import SwiftData

@Model
final class ReadingHistory {
    var id: UUID
    var title: String
    var url: String?              // web article URL or nil for local files
    var filePath: String?         // local or NAS path for files
    var fileType: FileType
    var progress: Double          // Reading fraction; web video histories retain playback seconds.
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

    var isWebVideoPlayback: Bool { fileType == .video && url != nil }

    var clampedFraction: Double {
        progress.isFinite ? min(max(progress, 0), 1) : 0
    }

    var progressSummary: String {
        if isWebVideoPlayback {
            let total = Int(max(0, progress.isFinite ? progress : 0))
            let hours = total / 3600
            let mins = (total % 3600) / 60
            let secs = total % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, mins, secs)
                : String(format: "%02d:%02d", mins, secs)
        }
        return "\(Int(clampedFraction * 100))%"
    }

    static func restoredIndex(progress: Double, count: Int) -> Int {
        guard count > 0, progress.isFinite else { return 0 }
        let clamped = min(max(progress, 0), 1)
        return max(0, min(count - 1, Int((clamped * Double(count)).rounded(.up)) - 1))
    }

    @MainActor
    static func find(
        in context: ModelContext,
        url: String? = nil,
        filePath: String? = nil,
        fileType: FileType? = nil,
        nasConfigID: String? = nil
    ) -> ReadingHistory? {
        let candidates: [ReadingHistory]
        if let filePath {
            candidates = (try? context.fetch(FetchDescriptor<ReadingHistory>(
                predicate: #Predicate { $0.filePath == filePath },
                sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)]
            ))) ?? []
        } else if let url {
            candidates = (try? context.fetch(FetchDescriptor<ReadingHistory>(
                predicate: #Predicate { $0.url == url },
                sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)]
            ))) ?? []
        } else {
            return nil
        }
        return candidates.first { entry in
            (fileType == nil || entry.fileType == fileType) &&
            (nasConfigID == nil || entry.nasConfigID == nasConfigID)
        }
    }

    @MainActor
    @discardableResult
    static func recordProgress(
        in context: ModelContext,
        historyItem: ReadingHistory?,
        title: String,
        url: String? = nil,
        filePath: String? = nil,
        fileType: FileType,
        progress: Double,
        thumbnailURLString: String? = nil,
        definitionID: String? = nil,
        nasConfigID: String? = nil,
        updateTitle: Bool = false,
        updateFilePath: Bool = false,
        updateMetadata: Bool = false
    ) -> ReadingHistory? {
        guard progress.isFinite else { return nil }
        let safeProgress = max(0, progress)
        let lookupByPath = !updateFilePath && filePath != nil
        let target = historyItem ?? find(
            in: context,
            url: lookupByPath ? nil : url,
            filePath: lookupByPath ? filePath : nil,
            fileType: fileType,
            nasConfigID: nasConfigID
        )

        let record: ReadingHistory
        if let existing = target {
            existing.progress = safeProgress
            existing.lastReadAt = Date()
            if updateTitle { existing.title = title }
            if updateFilePath, let filePath { existing.filePath = filePath }
            if updateMetadata {
                if let thumbnailURLString { existing.thumbnailURLString = thumbnailURLString }
                if let definitionID { existing.definitionID = definitionID }
            } else {
                if let thumbnailURLString, existing.thumbnailURLString == nil { existing.thumbnailURLString = thumbnailURLString }
                if let definitionID, existing.definitionID == nil { existing.definitionID = definitionID }
            }
            if let nasConfigID { existing.nasConfigID = nasConfigID }
            record = existing
        } else {
            let entry = ReadingHistory(
                title: title,
                url: url,
                filePath: filePath,
                fileType: fileType,
                progress: safeProgress,
                thumbnailURLString: thumbnailURLString
            )
            entry.definitionID = definitionID
            entry.nasConfigID = nasConfigID
            context.insert(entry)
            record = entry
        }
        try? context.save()
        return record
    }

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
    case article
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
        case .article: "doc.text"
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
