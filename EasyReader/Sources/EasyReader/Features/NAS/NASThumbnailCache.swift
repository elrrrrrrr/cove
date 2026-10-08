import UIKit
import AVFoundation
import CryptoKit
import ImageIO

/// File revisions and connection identity isolate thumbnails across SMB shares.
actor NASThumbnailCache {
    static let shared = NASThumbnailCache()
    private let pending = SharedTaskPool<String, UIImage>()
    private let imageSlots = AsyncWorkLimiter(limit: 4)
    private let videoSlots = AsyncWorkLimiter(limit: 2)
    private let disk: DiskDataCache

    init(root: URL? = nil) {
        let directory = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NASCoverCache", isDirectory: true)
        disk = DiskDataCache(root: directory, suffix: ".jpg", byteLimit: 300 * 1024 * 1024, ttl: 7 * 86400)
    }

    static func key(connectionID: String, entry: NASFileEntry, pixels: Int) -> String {
        let values = [connectionID, entry.path, String(entry.size),
                      entry.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "unknown", String(pixels), entry.fileType.rawValue]
        let context = values.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func thumbnail(for entry: NASFileEntry, connection: NASConnection, pixels: Int) async -> UIImage? {
        let key = Self.key(connectionID: connection.cacheIdentity, entry: entry, pixels: pixels)
        if let cached = ImageMemoryCache.shared.image(forKey: key) { return Task.isCancelled ? nil : cached }
        return await pending.value(for: key) {
            if let data = await self.disk.load(key) {
                let image = await Self.decode(data, pixels: pixels)
                if let image, !Task.isCancelled { ImageMemoryCache.shared.store(image, forKey: key); return image }
            }
            let image: UIImage?
            switch entry.fileType {
            case .image:
                image = await self.imageSlots.run { await Self.imageThumbnail(entry: entry, connection: connection, pixels: pixels) }
            case .video:
                image = await self.videoSlots.run { await Self.videoThumbnail(entry: entry, connection: connection, pixels: pixels) }
            default: image = nil
            }
            guard let image, !Task.isCancelled else { return nil }
            ImageMemoryCache.shared.store(image, forKey: key)
            let data = await Task.detached(priority: .utility) { image.jpegData(compressionQuality: 0.78) }.value
            if let data, !Task.isCancelled { await self.disk.store(data, for: key) }
            return Task.isCancelled ? nil : image
        }
    }

    func clear() async {
        await pending.clear()
        ImageMemoryCache.shared.clear()
        await disk.clear()
    }
    func diskUsageBytes() async -> Int { await disk.usageBytes() }

    private static func decode(_ data: Data, pixels: Int) async -> UIImage? {
        let task = Task.detached(priority: .utility) { ImageDecoder.decode(data, sizing: .thumbnail(pixels)) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func imageThumbnail(entry: NASFileEntry, connection: NASConnection, pixels: Int) async -> UIImage? {
        guard let client = connection.smbClient else { return nil }
        do {
            let length = entry.size > 0 ? min(entry.size, 256 * 1024) : 256 * 1024
            if let header = try? await client.readRange(at: entry.path, offset: 0, length: length), !Task.isCancelled {
                let thumbnail = await Task.detached(priority: .utility) { embeddedThumbnail(header, pixels: pixels) }.value
                if let thumbnail { return thumbnail }
            }
            guard !Task.isCancelled, entry.size <= 20_000_000 else { return nil }
            // The client also enforces its bounded read limit for unknown/changed file sizes.
            let data = try await client.readFile(at: entry.path)
            guard !Task.isCancelled else { return nil }
            return await decode(data, pixels: pixels)
        } catch { return nil }
    }

    private static func embeddedThumbnail(_ data: Data, pixels: Int) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func videoThumbnail(entry: NASFileEntry, connection: NASConnection, pixels: Int) async -> UIImage? {
        guard let client = connection.smbClient, !Task.isCancelled else { return nil }
        let operation = VideoThumbnailOperation(asset: SMBStreamLoader.makeAsset(client: client, remotePath: entry.path))
        let generator = operation.generator
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        return await withTaskCancellationHandler {
            do {
                let (image, _) = try await operation.generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                return Task.isCancelled ? nil : UIImage(cgImage: image)
            } catch { return nil }
        } onCancel: { operation.generator.cancelAllCGImageGeneration() }
    }
}

/// Immutable AVFoundation handle; cancellation may run concurrently with image generation.
private final class VideoThumbnailOperation: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    init(asset: AVAsset) { generator = AVAssetImageGenerator(asset: asset) }
}
