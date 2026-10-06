import Foundation

@MainActor final class FileSourceProvider: SourceProvider {
    let definition: SourceDefinition
    private let root: URL
    private let access: FolderAccessLease
    private var cache: [String: (date: Date, items: [ResourceItem])] = [:]
    init(definition: SourceDefinition, root: URL) throws {
        self.definition = definition; self.root = root
        self.access = FolderAccessLease(root)
    }
    func list(_ request: CollectionRequest) async throws -> ResourcePage {
        let key = request.locator
        let items: [ResourceItem]
        if !request.forceRefresh, let cached = cache[key], Date.now.timeIntervalSince(cached.date) < 60 { items = cached.items }
        else {
            let root = root, sourceID = definition.id
            let relative = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let directory = relative.isEmpty ? root : try ContainedPath.resolve(relative, under: root)
            items = try await Task.detached(priority: .userInitiated) {
                let urls = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles)
                return try urls.map { url in
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                    guard canonical.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
                        throw CoveError.message("文件夹中存在指向来源外部的链接")
                    }
                    let path = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return ResourceItem(sourceID: sourceID, title: url.lastPathComponent, locator: path,
                                        kind: .detect(path: url.path, isDirectory: values.isDirectory == true),
                                        byteSize: values.fileSize.map(Int64.init), modifiedAt: values.contentModificationDate)
                }.sorted {
                    if ($0.kind == .folder) != ($1.kind == .folder) { return $0.kind == .folder }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }.value
            if cache.count >= 128, let oldest = cache.min(by: { $0.value.date < $1.value.date }) { cache.removeValue(forKey: oldest.key) }
            cache[key] = (.now, items)
        }
        return ResourcePage(items: request.query.map { query in items.filter { $0.title.localizedCaseInsensitiveContains(query) } } ?? items)
    }
    func resolve(_ item: ResourceItem) async throws -> ResolvedContent {
        if item.kind == .folder { return .collection(item.locator) }
        let url = try ContainedPath.resolve(item.locator, under: root)
        switch item.kind {
        case .video, .audio: return .media(MediaAsset(url: url))
        case .comic: return .comic(ComicContent(localArchive: url))
        case .image: return .image(url)
        default: return .document(url)
        }
    }
    func fileURL(_ item: ResourceItem) -> URL? { try? ContainedPath.resolve(item.locator, under: root) }
    func close() { cache.removeAll(); access.close() }
}

private final class FolderAccessLease: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var active: Bool
    init(_ root: URL) { self.root = root; active = root.startAccessingSecurityScopedResource() }
    func close() {
        let stop = lock.withLock { let value = active; active = false; return value }
        if stop { root.stopAccessingSecurityScopedResource() }
    }
    deinit { close() }
}
