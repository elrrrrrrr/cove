import Foundation
import CryptoKit

/// Bounded snapshots for immediate list display while the page refreshes.
actor GalleryCache {
    private struct Envelope: Codable { let items: [ParsedItem]; let savedAt: Date }
    private static let shared = GalleryCache()
    private let disk: DiskDataCache
    private let ttl: TimeInterval

    init(root: URL? = nil, ttl: TimeInterval = 86400, byteLimit: Int = 32 * 1024 * 1024, countLimit: Int = 2000) {
        self.ttl = ttl
        let directory = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalleryCache", isDirectory: true)
        disk = DiskDataCache(root: directory, suffix: ".json", byteLimit: byteLimit, countLimit: countLimit, ttl: ttl)
    }
    private func key(_ url: URL) -> String {
        Insecure.MD5.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func save(_ items: [ParsedItem], for url: URL, now: Date = Date()) async {
        guard !items.isEmpty, let data = try? JSONEncoder().encode(Envelope(items: items, savedAt: now)) else { return }
        await disk.store(data, for: key(url), now: now)
    }
    func load(for url: URL, now: Date = Date()) async -> (items: [ParsedItem], savedAt: Date)? {
        guard let data = await disk.load(key(url), now: now),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              now.timeIntervalSince(envelope.savedAt) <= ttl, !envelope.items.isEmpty else { return nil }
        return (envelope.items, envelope.savedAt)
    }
    func clear() async { await disk.clear() }
    static func save(_ items: [ParsedItem], for url: URL) async { await shared.save(items, for: url) }
    static func load(for url: URL) async -> (items: [ParsedItem], savedAt: Date)? { await shared.load(for: url) }
    static func clearAll() async { await shared.clear() }
}
