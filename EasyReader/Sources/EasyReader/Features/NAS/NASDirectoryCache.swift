import Foundation

/// Connection-owned directory snapshots; refresh invalidates only the requested path.
actor NASDirectoryCache {
    private struct Entry { let items: [NASFileEntry]; let savedAt: Date; var access: UInt64 }
    private var entries: [String: Entry] = [:]
    private var generations: [String: UUID] = [:]
    private var subscribers: [UUID: Int] = [:]
    private var access: UInt64 = 0
    private var entryCount = 0
    private let ttl: TimeInterval
    private let directoryLimit: Int
    private let entryLimit: Int
    private let requests = SharedTaskPool<String, Result<[NASFileEntry], Error>>()

    init(ttl: TimeInterval = 60, directoryLimit: Int = 64, entryLimit: Int = 20_000) {
        self.ttl = ttl; self.directoryLimit = directoryLimit; self.entryLimit = entryLimit
    }
    func load(path: String, refresh: Bool = false, now: Date? = nil, fetch: @escaping @Sendable () async throws -> [NASFileEntry]) async throws -> [NASFileEntry] {
        let clock = now ?? Date()
        try Task.checkCancellation()
        if !refresh, let cached = entries[path], clock.timeIntervalSince(cached.savedAt) < ttl {
            access &+= 1; entries[path]?.access = access; return cached.items
        }
        if refresh || generations[path] == nil { generations[path] = UUID() }
        let generation = generations[path]!
        subscribers[generation, default: 0] += 1
        defer { release(path, generation: generation) }
        let result = await requests.value(for: generation.uuidString) {
            do { return .success(try await fetch()) } catch { return .failure(error) }
        }
        try Task.checkCancellation()
        guard generations[path] == generation, let result else { throw CancellationError() }
        let items = try result.get()
        remove(path)
        if items.count <= entryLimit {
            access &+= 1
            entries[path] = Entry(items: items, savedAt: now ?? Date(), access: access); entryCount += items.count
            if entries.count > directoryLimit || entryCount > entryLimit {
                for entry in entries.sorted(by: { $0.value.access < $1.value.access }) {
                    if entries.count <= directoryLimit && entryCount <= entryLimit { break }
                    remove(entry.key)
                }
            }
        }
        return items
    }
    private func release(_ path: String, generation: UUID) {
        guard let count = subscribers[generation] else { return }
        if count > 1 { subscribers[generation] = count - 1 }
        else {
            subscribers.removeValue(forKey: generation)
            if generations[path] == generation { generations.removeValue(forKey: path) }
        }
    }
    private func remove(_ path: String) { entryCount -= entries.removeValue(forKey: path)?.items.count ?? 0 }
    func clear() async {
        entries.removeAll(); generations.removeAll(); subscribers.removeAll(); entryCount = 0
        await requests.clear()
    }
}
