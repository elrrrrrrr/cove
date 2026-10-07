import Foundation
import CryptoKit

/// Disk-backed JSON cache for gallery item lists.
/// All file I/O is isolated to a private actor to avoid blocking the main thread.
enum GalleryCache {

    // MARK: - Envelope (savedAt kept for forward compatibility)

    private struct Envelope: Codable {
        let items:   [ParsedItem]
        let savedAt: Date
    }

    // MARK: - IO Actor (isolates disk reads/writes from main thread)

    private actor IO {
        static let shared = IO()

        private let cacheDir: URL = {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir  = docs.appendingPathComponent("GalleryCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }()

        func save(_ items: [ParsedItem], for url: URL) {
            let file     = cacheFile(for: url)
            let envelope = Envelope(items: items, savedAt: Date())
            guard let data = try? JSONEncoder().encode(envelope) else { return }
            try? data.write(to: file, options: .atomic)
        }

        func load(for url: URL) -> (items: [ParsedItem], savedAt: Date)? {
            let file = cacheFile(for: url)
            guard let data     = try? Data(contentsOf: file),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  !envelope.items.isEmpty else { return nil }
            return (envelope.items, envelope.savedAt)
        }

        func clearAll() {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        private func cacheFile(for url: URL) -> URL {
            let hash = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
            let key = hash.map { String(format: "%02x", $0) }.joined()
            return cacheDir.appendingPathComponent("\(key).json")
        }
    }

    // MARK: - Public async API

    static func save(_ items: [ParsedItem], for url: URL) async {
        await IO.shared.save(items, for: url)
    }

    static func load(for url: URL) async -> (items: [ParsedItem], savedAt: Date)? {
        await IO.shared.load(for: url)
    }

    static func clearAll() async {
        await IO.shared.clearAll()
    }
}
