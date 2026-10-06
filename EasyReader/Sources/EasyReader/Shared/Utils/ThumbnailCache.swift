import UIKit
import Foundation

private final class ThumbnailSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - ImageMemoryCache
//
// NSCache<NSURL, UIImage> is thread-safe and can be read synchronously from any context,
// including SwiftUI View.init. This is the "L0" layer that eliminates the blank-frame
// flash when CachedThumbnail is recreated during navigation.

final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSURL, UIImage>()

    /// L0 max decoded UIImage count (compressed in memory by OS).
    private static let l0MaxCount = 300

    private init() {
        cache.countLimit = Self.l0MaxCount
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }
}

// MARK: - ThumbnailCache
//
// Three-level cache:
//   L0 (ImageMemoryCache) — NSCache<URL, UIImage>  synchronous, no await needed
//   L1 (actor mem)        — [URL: Data] LRU, up to memMaxCount entries
//   L2 (disk)             — CoverCache/<host>/<url-path>, up to diskMaxBytes, mtime LRU

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    // ── tunables ────────────────────────────────────────────────────────
    private let memMaxCount  = 150
    private let diskMaxBytes = 500 * 1024 * 1024   // 500 MB

    // ── L1: actor-isolated Data LRU (tick-counter for O(1) touch) ────────
    private var mem: [URL: (data: Data, tick: UInt64)] = [:]
    private var tick: UInt64 = 0

    // ── L2: disk root ────────────────────────────────────────────────────
    private let root: URL

    // ── in-flight dedup ──────────────────────────────────────────────────
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    // ── URLSession with Safari UA ────────────────────────────────────────
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
        ]
        return URLSession(configuration: cfg, delegate: ThumbnailSessionDelegate(), delegateQueue: nil)
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("CoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Public

    func data(for url: URL, referer: URL? = nil) async -> Data? {
        // Handle data: URIs (e.g. data:image/jpeg;base64,...) — decode inline
        if url.scheme == "data" {
            return decodeDataURI(url)
        }

        // L1 hit — L0 (ImageMemoryCache) was already populated when this was first loaded
        if let entry = mem[url] { touch(mem: url); return entry.data }

        // L2 hit — read disk off the actor serial queue to avoid blocking concurrent loads
        let file = diskPath(for: url)
        if let d = await Self.readDisk(file: file) {
            store(mem: url, data: d)
            nonisolated(unsafe) let f = file
            Task.detached(priority: .utility) { Self.touchDisk(file: f) }
            if let img = UIImage(data: d) { ImageMemoryCache.shared.store(img, for: url) }
            return d
        }

        // Deduplicate concurrent fetches
        if let existing = inFlight[url] { return await existing.value }

        let refererCopy = referer
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            // Use provided referer (e.g. item page URL) so CDN anti-hotlinking passes.
            // Fall back to the image's own origin if no referer supplied.
            let ref = refererCopy ?? url
            request.setValue(ref.absoluteString, forHTTPHeaderField: "Referer")
            if let scheme = ref.scheme, let host = ref.host() {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
            guard let (d, resp) = try? await self.session.data(for: request),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  !d.isEmpty else { return nil }
            // If raw data is a valid image, use it directly.
            // Apply only the transformation declared by the matching site configuration.
            let imageData: Data
            if UIImage(data: d) != nil {
                imageData = d
            } else if let transform = SiteParserRegistry.imageTransform(for: url, referer: refererCopy),
                      let decrypted = SiteCrypto.decrypt(d, key: Data(transform.key.utf8), iv: Data(transform.iv.utf8)),
                      UIImage(data: decrypted) != nil {
                imageData = decrypted
            } else {
                return nil
            }
            await self.persist(imageData, url: url, file: file)
            return imageData
        }
        inFlight[url] = task
        let result = await task.value
        inFlight.removeValue(forKey: url)
        return result
    }

    /// Decodes a `data:` URI (e.g. `data:image/jpeg;base64,/9j/...`) into raw Data.
    private func decodeDataURI(_ url: URL) -> Data? {
        let str = url.absoluteString
        guard let commaIndex = str.firstIndex(of: ",") else { return nil }
        let payload = String(str[str.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              !data.isEmpty else { return nil }
        // Warm L0 cache
        if let img = UIImage(data: data) { ImageMemoryCache.shared.store(img, for: url) }
        return data
    }

    func clearAll() {
        mem.removeAll(); tick = 0
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func diskUsageBytes() -> Int {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
        else { return 0 }
        return e.compactMap { ($0 as? URL).flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }}.reduce(0, +)
    }

    // MARK: - Private

    private func persist(_ data: Data, url: URL, file: URL) {
        store(mem: url, data: data)
        if let img = UIImage(data: data) { ImageMemoryCache.shared.store(img, for: url) }
        // Write to disk off the actor queue
        nonisolated(unsafe) let f = file
        Task.detached(priority: .utility) {
            let dir = f.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: f, options: .atomic)
        }
        Task.detached(priority: .background) { await self.evictDiskIfNeeded() }
    }

    /// Read file from disk without blocking the actor queue.
    private static func readDisk(file: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: file)
        }.value
    }

    /// Touch mtime without blocking the actor queue.
    private static func touchDisk(file: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private func store(mem url: URL, data: Data) {
        tick += 1
        if mem[url] == nil && mem.count >= memMaxCount {
            evictOldestBatch()
        }
        mem[url] = (data, tick)
    }

    /// Evict ~25% of entries in one O(n) pass — amortizes to O(1) per insertion.
    private func evictOldestBatch() {
        let target = memMaxCount / 4
        guard target > 0 else { return }
        let sorted = mem.sorted { $0.value.tick < $1.value.tick }
        for entry in sorted.prefix(target) {
            mem.removeValue(forKey: entry.key)
        }
    }

    private func touch(mem url: URL) {
        tick += 1
        mem[url]?.tick = tick
    }

    private func diskPath(for url: URL) -> URL {
        let host = url.host() ?? "unknown"
        return url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
            .reduce(root.appendingPathComponent(host)) { $0.appendingPathComponent($1) }
    }


    private var isEvicting = false
    private func evictDiskIfNeeded() {
        guard !isEvicting else { return }
        isEvicting = true; defer { isEvicting = false }

        let fm = FileManager.default
        guard let e = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var files: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for case let f as URL in e {
            guard !f.hasDirectoryPath else { continue }
            if let rv = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                let sz = rv.fileSize ?? 0
                files.append((f, sz, rv.contentModificationDate ?? .distantPast))
                total += sz
            }
        }

        guard total > diskMaxBytes else { return }
        files.sort { $0.mtime < $1.mtime }
        let target = Int(Double(diskMaxBytes) * 0.75)
        for f in files {
            guard total > target else { break }
            try? fm.removeItem(at: f.url)
            total -= f.size
        }
    }
}

// MARK: - CachedThumbnail (SwiftUI view)

import SwiftUI

/// Thumbnail view with three-level cache: L0 NSCache (sync) → L1 actor mem → L2 disk → network.
/// The explicit init pre-populates @State from L0 so the very first render already shows the image.
struct CachedThumbnail: View {
    let url: URL?
    var placeholder: String = "photo"
    var referer: URL? = nil

    @State private var image: UIImage?

    init(url: URL?, placeholder: String = "photo", referer: URL? = nil) {
        self.url         = url
        self.placeholder = placeholder
        self.referer     = referer
        // Synchronous L0 read — no await, no blank frame on repeated navigation
        _image = State(initialValue: url.flatMap { ImageMemoryCache.shared.image(for: $0) })
    }

    var body: some View {
        // Color drives layout size; image overlaid with .top alignment so the
        // top portion of the image is visible when clipped. Placeholder icon uses
        // a separate .center overlay so it stays centred in all card sizes.
        Color(.secondarySystemBackground)
            .overlay(alignment: .top) {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, minHeight: 0)
                        .clipped()
                }
            }
            .overlay {
                if image == nil {
                    Image(systemName: placeholder)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            // L0 hit already handled in init — skip async path
            if let cached = ImageMemoryCache.shared.image(for: url) {
                image = cached; return
            }
            // L1/L2/network — show placeholder while waiting, then fade in
            image = nil
            if let data = await ThumbnailCache.shared.data(for: url, referer: referer) {
                withAnimation(.easeIn(duration: 0.15)) {
                    image = UIImage(data: data)
                }
            }
        }
    }
}
