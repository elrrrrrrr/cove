import Foundation

struct ContentResolution: Sendable {
    let content: ResolvedContent
}

@MainActor enum ContentResolver {
    static func offline(_ item: ResourceItem, library: LibraryStore) throws -> ResolvedContent? {
        guard let entry = library.entries.first(where: { $0.id == item.id }), let path = entry.offlineRelativePath else { return nil }
        let url = try ContainedPath.resolve(path, under: CoveStorage.data)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CoveError.message("离线文件已被移除，请重新下载") }
        switch item.kind {
        case .video, .audio: return .media(MediaAsset(url: url))
        case .comic: return .comic(ComicContent(localArchive: url))
        case .image: return .image(url)
        default: return .document(url)
        }
    }
}
