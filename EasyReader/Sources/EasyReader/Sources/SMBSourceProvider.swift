import Foundation

@MainActor final class SMBSourceProvider: SourceProvider {
    let definition: SourceDefinition
    let client: SMBClient
    let revision: String
    private var cache: [String: (date: Date, items: [ResourceItem])] = [:]
    init(definition: SourceDefinition, password: String, revision: String? = nil) {
        self.definition = definition
        self.revision = revision ?? definition.fingerprint
        self.client = SMBClient(connection: definition.source, password: password)
    }
    func list(_ request: CollectionRequest) async throws -> ResourcePage {
        let path = request.locator.isEmpty ? "/" : request.locator
        let items: [ResourceItem]
        if !request.forceRefresh, let cached = cache[path], Date.now.timeIntervalSince(cached.date) < 60 { items = cached.items }
        else {
            let contents = try await client.list(path: path)
            items = contents.map {
                ResourceItem(sourceID: definition.id, title: $0.name, locator: $0.path,
                             kind: .detect(path: $0.path, isDirectory: $0.isDirectory), byteSize: $0.size, modifiedAt: $0.modifiedAt)
            }.sorted {
                if ($0.kind == .folder) != ($1.kind == .folder) { return $0.kind == .folder }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            if cache.count >= 128, let oldest = cache.min(by: { $0.value.date < $1.value.date }) { cache.removeValue(forKey: oldest.key) }
            cache[path] = (.now, items)
        }
        return ResourcePage(items: request.query.map { query in items.filter { $0.title.localizedCaseInsensitiveContains(query) } } ?? items)
    }
    func resolve(_ item: ResourceItem) async throws -> ResolvedContent {
        switch item.kind {
        case .folder: return .collection(item.locator)
        case .video, .audio: return .media(MediaAsset(smbPath: item.locator))
        default:
            let url = try await ResourceAccess.shared.localFile(for: item, client: client, scope: revision)
            if item.kind == .comic { return .comic(ComicContent(localArchive: url)) }
            if item.kind == .image { return .image(url) }
            return .document(url)
        }
    }
    func close() { cache.removeAll(); Task { await client.disconnect() } }
}
