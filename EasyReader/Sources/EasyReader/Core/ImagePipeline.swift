import UIKit
import ImageIO
import AVFoundation
import Observation

struct ImageRequest: Hashable, Sendable {
    var url: URL
    var sourceID: String
    var sourceRevision: String
    var assetRevision: String = ""
    var pixels: Int
    var ttl: TimeInterval = 3600
    var video = false
    var rangeReader: (any RangeReader)?
    var remotePath: String?
    var headers: [String: String] = [:]
    var transform: SiteImageTransform?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    var rawKey: String {
        StableHash.of(ScriptJSON.encode([sourceID, sourceRevision, assetRevision, url.absoluteString,
                                         ScriptJSON.encode(headers), transform.map(ScriptJSON.encode) ?? "", video ? "video" : "image"]))
    }
    var key: String { rawKey + ":\(max(1, pixels))" }
}

struct DecodedImage: @unchecked Sendable {
    let image: UIImage
    var cost: Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }
}

final class DecodedImageCache: @unchecked Sendable {
    static let shared = DecodedImageCache()
    private final class Stored: NSObject {
        let image: UIImage
        let expires: Date
        init(_ image: UIImage, expires: Date) { self.image = image; self.expires = expires }
    }
    private let cache = NSCache<NSString, Stored>()
    init() { cache.countLimit = 300; cache.totalCostLimit = 96 * 1024 * 1024 }
    func get(_ key: String, now: Date = .now) -> DecodedImage? {
        guard let value = cache.object(forKey: key as NSString) else { return nil }
        guard value.expires > now else { cache.removeObject(forKey: key as NSString); return nil }
        return DecodedImage(image: value.image)
    }
    func put(_ image: DecodedImage, key: String, ttl: TimeInterval = 3600) {
        cache.setObject(Stored(image.image, expires: Date.now.addingTimeInterval(ttl)), forKey: key as NSString, cost: image.cost)
    }
    func clear() { cache.removeAllObjects() }
}

enum ImageDecoder {
    static func thumbnail(data: Data, pixels: Int) -> DecodedImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return thumbnail(source: source, pixels: pixels)
    }
    static func thumbnail(file: URL, pixels: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source: source, pixels: pixels)
    }
    private static func thumbnail(source: CGImageSource, pixels: Int) -> DecodedImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(pixels, 4096)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedImage(image: UIImage(cgImage: cg))
    }
}

actor ImagePipeline {
    static let shared = ImagePipeline()
    private let disk: DiskCache
    private let transport: any ImageTransport
    private let slots = AsyncSlots(limit: 4)
    private let decodeSlots = AsyncSlots(limit: 2)
    private var encoded: [String: (data: Data, tick: UInt64, expires: Date)] = [:]
    private var encodedBytes = 0
    private var tick: UInt64 = 0
    private let maxEncodedBytes = 24 * 1024 * 1024
    private struct Work {
        let id: UUID
        let task: Task<DecodedImage?, Never>
        var subscribers: Set<UUID>
    }
    private var work: [String: Work] = [:]
    init(root: URL = CoveStorage.cache.appendingPathComponent("images"), transport: any ImageTransport = HTTPImageTransport()) {
        disk = DiskCache(root: root, maxBytes: 256 * 1024 * 1024, maxEntries: 4000)
        self.transport = transport
    }

    func image(_ request: ImageRequest) async -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        if let decoded = DecodedImageCache.shared.get(request.key) { return decoded }
        let subscriber = UUID()
        let token: UUID
        let task: Task<DecodedImage?, Never>
        if var current = work[request.key] {
            current.subscribers.insert(subscriber); work[request.key] = current
            token = current.id; task = current.task
        } else {
            token = UUID()
            task = Task { await self.produce(request) }
            work[request.key] = Work(id: token, task: task, subscribers: [subscriber])
        }
        return await withTaskCancellationHandler {
            let result = await task.value
            if work[request.key]?.id == token { unsubscribe(key: request.key, id: subscriber) }
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { await self.unsubscribe(key: request.key, id: subscriber) }
        }
    }
    private func unsubscribe(key: String, id: UUID) {
        guard var current = work[key] else { return }
        current.subscribers.remove(id)
        if current.subscribers.isEmpty { current.task.cancel(); work.removeValue(forKey: key) }
        else { work[key] = current }
    }
    private func produce(_ request: ImageRequest) async -> DecodedImage? {
        guard await slots.acquire() else { return nil }
        let result = await decode(request)
        await slots.release()
        if let result, !Task.isCancelled { DecodedImageCache.shared.put(result, key: request.key, ttl: request.ttl) }
        return Task.isCancelled ? nil : result
    }
    private func decode(_ request: ImageRequest) async -> DecodedImage? {
        if request.url.isFileURL && !request.video {
            return await Task.detached(priority: .utility) { ImageDecoder.thumbnail(file: request.url, pixels: request.pixels) }.value
        }
        var bytes: Data?
        if var cached = encoded[request.rawKey], cached.expires > .now {
            tick += 1; cached.tick = tick; encoded[request.rawKey] = cached; bytes = cached.data
        } else if let cached = await disk.data(for: request.rawKey) { bytes = cached }
        if bytes == nil {
            do {
                try Task.checkCancellation()
                if request.video {
                    bytes = await VideoThumbnailDecoder.data(request, slots: decodeSlots)
                } else if request.url.scheme == "data" {
                    let value = request.url.absoluteString
                    guard value.utf8.count <= 28 * 1024 * 1024, let comma = value.firstIndex(of: ",") else { return nil }
                    bytes = Data(base64Encoded: String(value[value.index(after: comma)...]))
                } else {
                    bytes = try await transport.data(for: request)
                }
            } catch { return nil }
        }
        guard let bytes, !Task.isCancelled else { return nil }
        guard await decodeSlots.acquire() else { return nil }
        let decode = Task.detached(priority: .utility) { () -> (DecodedImage?, Data) in
            if let plain = ImageDecoder.thumbnail(data: bytes, pixels: request.pixels) { return (plain, bytes) }
            if let transform = request.transform,
               let decrypted = SiteCrypto.decrypt(bytes, key: Data(transform.key.utf8), iv: Data(transform.iv.utf8)) {
                return (ImageDecoder.thumbnail(data: decrypted, pixels: request.pixels), decrypted)
            }
            return (nil, bytes)
        }
        let result: (DecodedImage?, Data) = await withTaskCancellationHandler { await decode.value } onCancel: { decode.cancel() }
        await decodeSlots.release()
        guard result.0 != nil, !Task.isCancelled else { return nil }
        retain(result.1, key: request.rawKey, ttl: request.ttl)
        try? await disk.store(result.1, for: request.rawKey, ttl: request.ttl)
        return result.0
    }
    private func retain(_ data: Data, key: String, ttl: TimeInterval) {
        guard data.count <= maxEncodedBytes else { return }
        if let previous = encoded[key] { encodedBytes -= previous.data.count }
        tick += 1; encoded[key] = (data, tick, Date.now.addingTimeInterval(ttl)); encodedBytes += data.count
        while encodedBytes > maxEncodedBytes, let victim = encoded.min(by: { $0.value.tick < $1.value.tick }) {
            encodedBytes -= victim.value.data.count; encoded.removeValue(forKey: victim.key)
        }
    }
    func clear() async throws {
        for value in work.values { value.task.cancel() }; work.removeAll()
        encoded.removeAll(); encodedBytes = 0; DecodedImageCache.shared.clear()
        try await disk.clear()
    }
}

private final class GeneratorHandle: @unchecked Sendable {
    let value: AVAssetImageGenerator
    init(_ value: AVAssetImageGenerator) { self.value = value }
}

private enum VideoThumbnailDecoder {
    static func data(_ request: ImageRequest, slots: AsyncSlots) async -> Data? {
        guard await slots.acquire() else { return nil }
        let task = Task.detached(priority: .utility) { () -> Data? in
            do {
                let asset: AVAsset
                if let reader = request.rangeReader, let path = request.remotePath {
                    asset = try SMBStreamLoader.asset(client: reader, path: path)
                } else { asset = AVURLAsset(url: request.url) }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: min(2400, request.pixels), height: min(2400, request.pixels))
                let handle = GeneratorHandle(generator)
                return try await withTaskCancellationHandler {
                    let generated = try await generator.image(at: .zero)
                    try Task.checkCancellation()
                    return UIImage(cgImage: generated.image).jpegData(compressionQuality: 0.75)
                } onCancel: { handle.value.cancelAllCGImageGeneration() }
            } catch { return nil }
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        await slots.release()
        return result
    }
}
