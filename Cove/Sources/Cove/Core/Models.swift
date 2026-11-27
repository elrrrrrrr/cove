import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - SwiftData Models (preserve schema compatibility with v1 stores)

@Model
final class BookmarkSite {
    var id: UUID
    var name: String
    var urlString: String
    var category: SiteCategory
    var faviconData: Data?
    var note: String
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

@Model
final class FavoriteVideo {
    var id: UUID
    var title: String
    var pageURLString: String
    var thumbnailURLString: String?
    var duration: String
    var siteName: String
    var definitionID: String?
    var isComic: Bool = false
    var isArticle: Bool = false
    var addedAt: Date
    var isPinned: Bool = false
    var pinOrder: Int = 0

    var pageURL: URL? { URL(string: pageURLString) }
    var thumbnailURL: URL? { thumbnailURLString.flatMap { URL(string: $0) } }
    var contentKind: ItemKind { isArticle ? .article : (isComic ? .comic : .video) }
    var contentLabel: String { isArticle ? "图文" : (isComic ? "漫画" : "视频") }
    var contentIcon: String {
        isArticle ? "doc.text" : (isComic ? "photo.on.rectangle.angled" : "play.rectangle.fill")
    }

    init(
        title: String,
        pageURLString: String,
        thumbnailURLString: String? = nil,
        duration: String = "",
        siteName: String = "",
        isComic: Bool = false,
        isArticle: Bool = false,
        definitionID: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.pageURLString = pageURLString
        self.thumbnailURLString = thumbnailURLString
        self.duration = duration
        self.siteName = siteName
        self.isComic = isComic
        self.isArticle = isArticle
        self.addedAt = Date()
        self.definitionID = definitionID
    }
}

@Model
final class ReadingHistory {
    var id: UUID
    var title: String
    var url: String?
    var filePath: String?
    var fileType: FileType
    var progress: Double
    var lastReadAt: Date
    var thumbnailData: Data?
    var thumbnailURLString: String?
    var definitionID: String?
    var nasConfigID: String?

    var thumbnailURL: URL? { thumbnailURLString.flatMap { URL(string: $0) } }
    var isWebVideoPlayback: Bool { fileType == .video && url != nil }
    var clampedFraction: Double { progress.isFinite ? min(max(progress, 0), 1) : 0 }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
            return trimmed.isEmpty ? "未命名记录" : trimmed
        }
        let segment = u.lastPathComponent
        return (segment.isEmpty || segment == "/") ? (u.host() ?? trimmed) : segment
    }

    var progressSummary: String {
        if isWebVideoPlayback {
            let total = Int(max(0, progress.isFinite ? progress : 0))
            let hours = total / 3600, mins = (total % 3600) / 60, secs = total % 60
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
        return candidates.first {
            (fileType == nil || $0.fileType == fileType) &&
            (nasConfigID == nil || $0.nasConfigID == nasConfigID)
        }
    }

    @MainActor
    @discardableResult
    static func recordProgress(
        in context: ModelContext,
        historyItem: ReadingHistory? = nil,
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
        let safe = max(0, progress)
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
            existing.progress = safe
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
                progress: safe,
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

@Model
final class OfflineItem {
    var id: UUID
    var title: String
    var sourceURL: String?
    var localPath: String
    var fileType: FileType
    var savedAt: Date
    var fileSizeBytes: Int64
    var thumbnailData: Data?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    init(title: String, sourceURL: String? = nil, localPath: String, fileType: FileType, fileSizeBytes: Int64 = 0) {
        self.id = UUID()
        self.title = title
        self.sourceURL = sourceURL
        self.localPath = localPath
        self.fileType = fileType
        self.savedAt = Date()
        self.fileSizeBytes = fileSizeBytes
    }
}

@Model
final class NASConfig {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var shareName: String
    var isActive: Bool

    var requiresSMBSetup: Bool { host.isEmpty || shareName.isEmpty }

    init(name: String, host: String, port: Int = 445, username: String, shareName: String) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.shareName = shareName
        self.isActive = false
    }
}

// MARK: - Supporting Value Types

enum SiteCategory: String, CaseIterable, Identifiable, Codable {
    case video = "视频", comic = "漫画", image = "图片", novel = "小说", news = "新闻", other = "其他"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .video: "play.rectangle.fill"
        case .comic: "photo.on.rectangle.angled"
        case .image: "photo.fill"
        case .novel: "doc.text.fill"
        case .news:  "newspaper.fill"
        case .other: "safari.fill"
        }
    }
}

enum FileType: String, Codable, Sendable {
    case web, article, pdf, cbz, cbr, epub, txt, video, audio, image, comic, unknown

    var systemImage: String {
        switch self {
        case .web: "globe"
        case .article, .txt: "doc.text"
        case .pdf: "doc.richtext"
        case .cbz, .cbr: "photo.on.rectangle"
        case .epub: "book"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .image: "photo"
        case .comic: "photo.on.rectangle.angled"
        case .unknown: "doc"
        }
    }

    static func detect(fromPath path: String) -> FileType {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": .pdf
        case "cbz": .cbz
        case "cbr": .cbr
        case "epub": .epub
        case "txt", "md": .txt
        case "mp4", "mov", "m4v", "mkv", "avi", "ts", "flv": .video
        case "mp3", "m4a", "flac", "aac", "wav", "ogg", "opus", "wma", "aiff": .audio
        case "jpg", "jpeg", "png", "webp", "gif", "heic": .image
        default: .unknown
        }
    }
}

enum ItemKind: Sendable {
    case video, navLink, comic, article

    var stringValue: String {
        switch self {
        case .video: "video"
        case .navLink: "navLink"
        case .comic: "comic"
        case .article: "article"
        }
    }

    init?(string: String) {
        switch string {
        case "video": self = .video
        case "navLink": self = .navLink
        case "comic": self = .comic
        case "article": self = .article
        default: return nil
        }
    }
}

enum BrowserLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case list, bento, portrait
    var id: String { rawValue }
    var title: String {
        switch self {
        case .list: "列表"
        case .bento: "Bento"
        case .portrait: "海报"
        }
    }
    var icon: String {
        switch self {
        case .list: "list.bullet"
        case .bento: "rectangle.grid.2x2"
        case .portrait: "square.grid.3x3"
        }
    }
    static func defaultLayout(for kind: ItemKind) -> BrowserLayout {
        switch kind {
        case .video: .bento
        case .comic: .portrait
        case .navLink, .article: .list
        }
    }
    static func preferenceKey(source: String, location: String) -> String {
        "browserLayout.\(source).\(location.utf8.reduce(0) { ($0 &<< 5) &+ $0 &+ Int($1) })"
    }
}

struct ParsedItem: Identifiable, Hashable, Sendable, Codable {
    var id: UUID = UUID()
    let title: String
    let pageURL: URL
    let thumbnail: URL?
    let duration: String
    let extra: String
    let extraTags: [String]
    let titleImage: URL?

    enum CodingKeys: String, CodingKey { case title, pageURL, thumbnail, duration, extra, titleImage }

    init(title: String, pageURL: URL, thumbnail: URL?, duration: String, extra: String, titleImage: URL? = nil) {
        self.title = title
        self.pageURL = pageURL
        self.thumbnail = thumbnail
        self.duration = duration
        self.extra = extra
        self.extraTags = Self.parseTags(extra)
        self.titleImage = titleImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let extraValue = try c.decode(String.self, forKey: .extra)
        self.title = try c.decode(String.self, forKey: .title)
        self.pageURL = try c.decode(URL.self, forKey: .pageURL)
        self.thumbnail = try c.decodeIfPresent(URL.self, forKey: .thumbnail)
        self.duration = try c.decode(String.self, forKey: .duration)
        self.extra = extraValue
        self.extraTags = Self.parseTags(extraValue)
        self.titleImage = try c.decodeIfPresent(URL.self, forKey: .titleImage)
    }

    static func parseTags(_ extra: String) -> [String] {
        let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        for sep in ["、", "，", ",", "/", "|"] where trimmed.contains(sep) {
            return trimmed.split(separator: Character(sep)).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return [trimmed]
    }
}

extension UTType {
    static let coveSite = UTType(exportedAs: "dev.cove.site")
}

// MARK: - Local Storage Paths

enum LocalAppStorage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cove", isDirectory: true)
    }
    static var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    static var data: URL { root.appendingPathComponent("data", isDirectory: true) }

    static func prepareModelStore() throws -> (url: URL, freshInstall: Bool) {
        let fm = FileManager.default
        let sourceStore = ModelConfiguration().url
        let destination = data.appendingPathComponent("Cove.store")
        let existed = fm.fileExists(atPath: destination.path) || fm.fileExists(atPath: sourceStore.path)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: sourceStore.path) {
            for suffix in ["-wal", "-shm", ""] {
                let source = URL(fileURLWithPath: sourceStore.path + suffix)
                let target = URL(fileURLWithPath: destination.path + suffix)
                if fm.fileExists(atPath: source.path) {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: source, to: target)
                }
            }
        }
        return (destination, !existed)
    }
}
