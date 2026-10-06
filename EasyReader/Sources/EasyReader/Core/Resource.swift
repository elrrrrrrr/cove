import Foundation
import CryptoKit

enum ResourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case folder, video, comic, ebook, audio, image, web, unknown
    var id: String { rawValue }
    var label: String {
        switch self {
        case .folder: "文件夹"
        case .video: "视频"
        case .comic: "漫画"
        case .ebook: "电子书"
        case .audio: "音乐"
        case .image: "图片"
        case .web: "网页"
        case .unknown: "其他"
        }
    }
    var icon: String {
        switch self {
        case .folder: "folder"
        case .video: "play.rectangle"
        case .comic: "photo.on.rectangle"
        case .ebook: "book"
        case .audio: "music.note"
        case .image: "photo"
        case .web: "globe"
        case .unknown: "doc"
        }
    }
    static func detect(path: String, isDirectory: Bool = false) -> Self {
        if isDirectory { return .folder }
        switch (path as NSString).pathExtension.lowercased() {
        case "cbz", "zip", "cbr", "rar": return .comic
        case "epub", "pdf", "txt": return .ebook
        case "mp4", "m4v", "mov", "mkv", "avi", "ts", "webm": return .video
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "ogg": return .audio
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp": return .image
        default: return .unknown
        }
    }
}

struct ResourceItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let sourceID: String
    let identity: String?
    var title: String
    var locator: String
    var kind: ResourceKind
    var thumbnail: String?
    var subtitle: String
    var tags: [String]
    var byteSize: Int64?
    var modifiedAt: Date?
    var format: String?
    var episodeCount: Int?

    init(sourceID: String, title: String, locator: String, kind: ResourceKind,
         identity: String? = nil, thumbnail: String? = nil, subtitle: String = "",
         tags: [String] = [], byteSize: Int64? = nil, modifiedAt: Date? = nil,
         format: String? = nil, episodeCount: Int? = nil) {
        self.id = StableHash.of(sourceID + "\u{0}" + (identity ?? locator))
        self.sourceID = sourceID
        self.identity = identity
        self.title = title
        self.locator = locator
        self.kind = kind
        self.thumbnail = thumbnail
        self.subtitle = subtitle
        self.tags = tags
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.format = format
        self.episodeCount = episodeCount
    }
    var fileExtension: String {
        format ?? URL(string: locator)?.pathExtension.lowercased() ?? (locator as NSString).pathExtension.lowercased()
    }
    var revision: String { "\(byteSize ?? -1):\(modifiedAt?.timeIntervalSince1970 ?? 0)" }
}

enum StableHash {
    static func of(_ value: String) -> String { of(Data(value.utf8)) }
    static func of(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}

struct CollectionRequest: Hashable, Sendable {
    var locator: String
    var query: String? = nil
    var cursor: String? = nil
    var forceRefresh = false
}

struct ResourcePage: Codable, Sendable {
    var items: [ResourceItem]
    var nextCursor: String?
}

struct MediaAsset: Sendable {
    var url: URL?
    var headers: [String: String] = [:]
    var smbPath: String?
    var nextEpisode: ResourceItem?
    var format: String?
}

struct ComicChapter: Codable, Hashable, Sendable, Identifiable {
    var id: String { locator }
    var title: String
    var locator: String
}

struct ComicContent: Sendable {
    var title: String?
    var author: String?
    var status: String?
    var description: String?
    var cover: String?
    var tags: [String] = []
    var chapters: [ComicChapter] = []
    var images: [String] = []
    var localArchive: URL?
}

enum ResolvedContent: Sendable {
    case media(MediaAsset)
    case comic(ComicContent)
    case document(URL)
    case image(URL)
    case web(URL)
    case collection(String)
}

@MainActor protocol SourceProvider: AnyObject {
    var definition: SourceDefinition { get }
    func list(_ request: CollectionRequest) async throws -> ResourcePage
    func resolve(_ item: ResourceItem) async throws -> ResolvedContent
    func close()
}

enum CoveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
