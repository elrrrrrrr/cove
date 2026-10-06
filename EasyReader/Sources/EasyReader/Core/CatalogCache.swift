import Foundation

/// A separate list-cache interface backed by the same indexed disk implementation.
/// One actor owns the shared directory across every web source.
actor CatalogCache {
    static let shared = CatalogCache()
    private let disk: DiskCache
    init(root: URL = CoveStorage.cache.appendingPathComponent("catalog")) {
        disk = DiskCache(root: root, maxBytes: 40 * 1024 * 1024, maxEntries: 500)
    }
    func page(_ key: String) async -> ResourcePage? {
        guard let data = await disk.data(for: key) else { return nil }
        return try? JSONDecoder().decode(ResourcePage.self, from: data)
    }
    func store(_ page: ResourcePage, key: String) async throws {
        try await disk.store(JSONEncoder().encode(page), for: key, ttl: 86400)
    }
    func clear() async throws { try await disk.clear() }
}
