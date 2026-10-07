import UIKit
import Foundation
import CryptoKit

/// Immutable ownership and transform snapshot for one image request.
struct ThumbnailRequest: Hashable, Sendable {
    let url: URL
    let referer: URL?
    let definitionID: String?
    let transform: SiteImageTransform?
    let cacheID: String

    init(url: URL, referer: URL? = nil, definitionID: String? = nil) {
        self.url = url; self.referer = referer; self.definitionID = definitionID
        transform = SiteParserRegistry.imageTransform(for: url, referer: referer, definitionID: definitionID)
        let fields = [url.absoluteString, referer?.absoluteString ?? "", definitionID ?? "", transform?.key ?? "", transform?.iv ?? ""]
        let context = fields.map { "\($0.utf8.count):\($0)" }.joined()
        cacheID = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ImageMemoryCache
//
// NSCache<NSString, UIImage> is thread-safe and can be read synchronously from any context,
// including SwiftUI View.init. This is the "L0" layer that eliminates the blank-frame
// flash when CachedThumbnail is recreated during navigation.

final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSString, UIImage>()

    /// Soft count limit for decoded images; the full image budget is a separate follow-up.
    private static let l0MaxCount = 300

    private init() {
        cache.countLimit = Self.l0MaxCount
    }

    func store(_ image: UIImage, for request: ThumbnailRequest) {
        cache.setObject(image, forKey: request.cacheID as NSString)
    }
    func image(for request: ThumbnailRequest) -> UIImage? {
        cache.object(forKey: request.cacheID as NSString)
    }
    func store(_ image: UIImage, for url: URL) { store(image, for: ThumbnailRequest(url: url)) }
    func image(for url: URL) -> UIImage? { image(for: ThumbnailRequest(url: url)) }
}

// MARK: - ThumbnailCache
//
// Three-level cache:
//   L0 (ImageMemoryCache) — NSCache<NSString, UIImage>  synchronous, no await needed
//   L1 (actor mem)        — [request ID: Data] LRU, up to memMaxCount entries
//   L2 (disk)             — CoverCache/<request-hash>.image, up to diskMaxBytes, mtime LRU

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    // ── tunables ────────────────────────────────────────────────────────
    private let memMaxCount  = 150
    private let diskMaxBytes = 500 * 1024 * 1024   // 500 MB

    // ── L1: actor-isolated Data LRU (tick-counter for O(1) touch) ────────
    private var mem: [String: (data: Data, tick: UInt64)] = [:]
    private var tick: UInt64 = 0

    // ── L2: disk root ────────────────────────────────────────────────────
    private let root: URL

    // ── in-flight dedup ──────────────────────────────────────────────────
    private var inFlight: [String: Task<Data?, Never>] = [:]

    // ── URLSession with Safari UA ────────────────────────────────────────
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
        ]
        return URLSession(configuration: cfg)
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("CoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Public

    func data(for url: URL, referer: URL? = nil, definitionID: String? = nil) async -> Data? {
        await data(for: ThumbnailRequest(url: url, referer: referer, definitionID: definitionID))
    }

    func data(for imageRequest: ThumbnailRequest) async -> Data? {
        let url = imageRequest.url, key = imageRequest.cacheID
        if url.scheme == "data" { return decodeDataURI(imageRequest) }
        if let entry = mem[key] { touch(mem: key); return entry.data }
        let file = root.appendingPathComponent(key + ".image")
        if let data = await Self.readDisk(file: file), let image = UIImage(data: data) {
            store(mem: key, data: data)
            Task.detached(priority: .utility) { Self.touchDisk(file: file) }
            ImageMemoryCache.shared.store(image, for: imageRequest)
            return data
        }
        // Only unscoped requests may reuse caches without an ownership signature.
        if imageRequest.definitionID == nil, imageRequest.referer == nil {
            let oldHash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            let oldFiles = [root.appendingPathComponent(oldHash + ".image"), Self.legacyFile(for: url, under: root)].compactMap { $0 }
            for oldFile in oldFiles {
                if let data = await Self.readDisk(file: oldFile), UIImage(data: data) != nil {
                    persist(data, request: imageRequest, file: file); return data
                }
            }
        }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            let ref = imageRequest.referer ?? url
            request.setValue(ref.absoluteString, forHTTPHeaderField: "Referer")
            if var origin = URLComponents(url: ref, resolvingAgainstBaseURL: true) {
                origin.path = ""; origin.query = nil; origin.fragment = nil; origin.user = nil; origin.password = nil
                request.setValue(origin.string, forHTTPHeaderField: "Origin")
            }
            guard let (data, response) = try? await self.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            let decoded: Data
            if UIImage(data: data) != nil { decoded = data }
            else if let transform = imageRequest.transform,
                    let plain = SiteCrypto.decrypt(data, key: Data(transform.key.utf8), iv: Data(transform.iv.utf8)),
                    UIImage(data: plain) != nil { decoded = plain }
            else { return nil }
            self.persist(decoded, request: imageRequest, file: file)
            return decoded
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    /// Decodes a `data:` URI (e.g. `data:image/jpeg;base64,/9j/...`) into raw Data.
    private func decodeDataURI(_ request: ThumbnailRequest) -> Data? {
        let str = request.url.absoluteString
        guard let commaIndex = str.firstIndex(of: ",") else { return nil }
        let payload = String(str[str.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              !data.isEmpty else { return nil }
        // Warm L0 cache
        if let img = UIImage(data: data) { ImageMemoryCache.shared.store(img, for: request) }
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

    private func persist(_ data: Data, request: ThumbnailRequest, file: URL) {
        store(mem: request.cacheID, data: data)
        if let img = UIImage(data: data) { ImageMemoryCache.shared.store(img, for: request) }
        // Write to disk off the actor queue
        let f = file
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

    private func store(mem url: String, data: Data) {
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

    private func touch(mem url: String) {
        tick += 1
        mem[url]?.tick = tick
    }

    static func legacyFile(for url: URL, under root: URL) -> URL? {
        guard let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return try? ReaderContainedPath.resolve(([host] + parts).joined(separator: "/"), under: root)
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
    var placeholder: String = "photo"
    private let request: ThumbnailRequest?

    @State private var image: UIImage?

    init(url: URL?, placeholder: String = "photo", referer: URL? = nil, definitionID: String? = nil) {
        self.placeholder = placeholder
        request = url.map { ThumbnailRequest(url: $0, referer: referer, definitionID: definitionID) }
        // Synchronous L0 read — no await, no blank frame on repeated navigation
        _image = State(initialValue: request.flatMap { ImageMemoryCache.shared.image(for: $0) })
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
        .task(id: request) {
            guard let request else { image = nil; return }
            // L0 hit already handled in init — skip async path
            if let cached = ImageMemoryCache.shared.image(for: request) {
                image = cached; return
            }
            // L1/L2/network — show placeholder while waiting, then fade in
            image = nil
            if let data = await ThumbnailCache.shared.data(for: request) {
                withAnimation(.easeIn(duration: 0.15)) {
                    image = UIImage(data: data)
                }
            }
        }
    }
}
