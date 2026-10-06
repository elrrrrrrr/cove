import UIKit
import AVFoundation
import CryptoKit
import ImageIO

/// Caches downsampled thumbnails for NAS files (images + videos), keyed by path.
/// Supports SMB (streaming), DSM (HTTP URL), and fnOS (signed HTTP URL).
actor NASThumbnailCache {
    static let shared = NASThumbnailCache()

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var activeImageThumbnailTasks = 0
    private var waitingImageThumbnailSlots: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var waitingImageThumbnailOrder: [UUID] = []
    private var activeVideoThumbnailTasks = 0
    private var waitingVideoThumbnailSlots: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var waitingVideoThumbnailOrder: [UUID] = []

    /// Max file size we'll attempt to thumbnail for images (skip huge RAW files, etc.)
    private let maxImageSize = 20_000_000  // 20 MB
    private let imageHeaderReadBytes = 256 * 1024
    private let imageThumbnailPixelSize = 240
    private let maxConcurrentImageThumbnails = 4
    private let maxConcurrentVideoThumbnails = 2
    private let diskMaxBytes = 300 * 1024 * 1024
    private let root: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = caches.appendingPathComponent("NASCoverCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Image thumbnail

    func thumbnail(for path: String, fileSize: Int, connection: NASConnection) async -> UIImage? {
        let key = cacheKey(for: path)
        if let cached = cache[key] { return cached }
        if let diskImage = await loadDiskImage(for: key) {
            cache[key] = diskImage
            return diskImage
        }
        if let existing = inFlight[key] { return await existing.value }

        let maxImageSize = maxImageSize
        let headerReadBytes = imageHeaderReadBytes
        let maxPixelSize = imageThumbnailPixelSize

        let task = Task<UIImage?, Never> {
            let slotID = UUID()
            guard await self.acquireImageThumbnailSlot(id: slotID) else { return nil }

            let result: UIImage?
            if Task.isCancelled {
                result = nil
            } else {
                result = await Self.makeImageThumbnail(
                    for: path,
                    fileSize: fileSize,
                    connection: connection,
                    maxImageSize: maxImageSize,
                    headerReadBytes: headerReadBytes,
                    maxPixelSize: maxPixelSize
                )
            }

            if let result, !Task.isCancelled {
                await self.store(result, for: key)
            }

            await self.releaseImageThumbnailSlot()
            return Task.isCancelled ? nil : result
        }

        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    // MARK: - Video thumbnail

    func videoThumbnail(for path: String, connection: NASConnection) async -> UIImage? {
        let key = cacheKey(for: path)
        if let cached = cache[key] { return cached }
        if let diskImage = await loadDiskImage(for: key) {
            cache[key] = diskImage
            return diskImage
        }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> {
            let slotID = UUID()
            guard await self.acquireVideoThumbnailSlot(id: slotID) else { return nil }

            let result: UIImage?
            if Task.isCancelled {
                result = nil
            } else {
                let asset: AVURLAsset?

                if let client = connection.smbClient {
                    // SMB: use streaming asset
                    asset = SMBStreamLoader.makeAsset(client: client, remotePath: path)
                } else {
                    asset = nil
                }

                if let asset {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 240, height: 240)

                    let time = CMTime(seconds: 1, preferredTimescale: 600)
                    do {
                        let (cgImage, _) = try await generator.image(at: time)
                        let thumb = UIImage(cgImage: cgImage)
                        await self.store(thumb, for: key)
                        result = thumb
                    } catch {
                        result = nil
                    }
                } else {
                    result = nil
                }
            }

            await self.releaseVideoThumbnailSlot()
            return result
        }

        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    func clear() {
        cache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        waitingImageThumbnailSlots.values.forEach { $0.resume(returning: false) }
        waitingImageThumbnailSlots.removeAll()
        waitingImageThumbnailOrder.removeAll()
        activeImageThumbnailTasks = 0
        waitingVideoThumbnailSlots.values.forEach { $0.resume(returning: false) }
        waitingVideoThumbnailSlots.removeAll()
        waitingVideoThumbnailOrder.removeAll()
        activeVideoThumbnailTasks = 0
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cancel(path: String) {
        let key = cacheKey(for: path)
        inFlight[key]?.cancel()
        inFlight.removeValue(forKey: key)
    }

    func diskUsageBytes() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }

        return enumerator.compactMap { ($0 as? URL).flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }}.reduce(0, +)
    }

    private func store(_ image: UIImage, for key: String) {
        cache[key] = image
        persistDisk(image, for: key)
    }

    private static func makeImageThumbnail(
        for path: String,
        fileSize: Int,
        connection: NASConnection,
        maxImageSize: Int,
        headerReadBytes: Int,
        maxPixelSize: Int
    ) async -> UIImage? {
        do {
            if let client = connection.smbClient {
                if let header = try? await client.readRange(
                    at: path,
                    offset: 0,
                    length: headerLength(fileSize: fileSize, headerReadBytes: headerReadBytes)
                ), let thumbnail = embeddedThumbnail(from: header, maxPixelSize: maxPixelSize) {
                    return thumbnail
                }

                guard canReadFullImage(fileSize: fileSize, maxImageSize: maxImageSize) else { return nil }
                let data = try await client.readFile(at: path)
                return downsampledImage(from: data, maxPixelSize: maxPixelSize)
            }

            return nil
        } catch {
            return nil
        }
    }

    private static func headerLength(fileSize: Int, headerReadBytes: Int) -> Int {
        guard fileSize > 0 else { return headerReadBytes }
        return max(1, min(fileSize, headerReadBytes))
    }

    private static func canReadFullImage(fileSize: Int, maxImageSize: Int) -> Bool {
        fileSize == 0 || fileSize <= maxImageSize
    }

    private static func fetchHTTPData(from url: URL, byteRange: ClosedRange<Int>? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let byteRange {
            request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound)", forHTTPHeaderField: "Range")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func embeddedThumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private static func downsampledImage(from data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private func loadDiskImage(for key: String) async -> UIImage? {
        let file = diskPath(for: key)
        guard let image = await Self.readDiskImage(file: file) else { return nil }
        nonisolated(unsafe) let diskFile = file
        Task.detached(priority: .utility) {
            Self.touchDisk(file: diskFile)
        }
        return image
    }

    private func persistDisk(_ image: UIImage, for key: String) {
        guard let data = image.jpegData(compressionQuality: 0.78) ?? image.pngData() else { return }
        let file = diskPath(for: key)
        nonisolated(unsafe) let diskFile = file
        Task.detached(priority: .utility) {
            let dir = diskFile.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: diskFile, options: .atomic)
        }
        Task.detached(priority: .background) {
            await self.evictDiskIfNeeded()
        }
    }

    private static func readDiskImage(file: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return UIImage(data: data)
        }.value
    }

    private static func touchDisk(file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private func cacheKey(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskPath(for key: String) -> URL {
        let prefix = String(key.prefix(2))
        return root.appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent("\(key).jpg")
    }

    private func acquireImageThumbnailSlot(id: UUID) async -> Bool {
        if activeImageThumbnailTasks < maxConcurrentImageThumbnails {
            activeImageThumbnailTasks += 1
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waitingImageThumbnailSlots[id] = continuation
                waitingImageThumbnailOrder.append(id)
            }
        } onCancel: {
            Task {
                await NASThumbnailCache.shared.cancelImageThumbnailSlotWaiter(id)
            }
        }
    }

    private func cancelImageThumbnailSlotWaiter(_ id: UUID) {
        guard let continuation = waitingImageThumbnailSlots.removeValue(forKey: id) else { return }
        waitingImageThumbnailOrder.removeAll { $0 == id }
        continuation.resume(returning: false)
    }

    private func releaseImageThumbnailSlot() {
        while !waitingImageThumbnailOrder.isEmpty {
            let id = waitingImageThumbnailOrder.removeFirst()
            if let continuation = waitingImageThumbnailSlots.removeValue(forKey: id) {
                continuation.resume(returning: true)
                return
            }
        }

        activeImageThumbnailTasks = max(activeImageThumbnailTasks - 1, 0)
    }

    private func acquireVideoThumbnailSlot(id: UUID) async -> Bool {
        if activeVideoThumbnailTasks < maxConcurrentVideoThumbnails {
            activeVideoThumbnailTasks += 1
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waitingVideoThumbnailSlots[id] = continuation
                waitingVideoThumbnailOrder.append(id)
            }
        } onCancel: {
            Task {
                await NASThumbnailCache.shared.cancelVideoThumbnailSlotWaiter(id)
            }
        }
    }

    private func cancelVideoThumbnailSlotWaiter(_ id: UUID) {
        guard let continuation = waitingVideoThumbnailSlots.removeValue(forKey: id) else { return }
        waitingVideoThumbnailOrder.removeAll { $0 == id }
        continuation.resume(returning: false)
    }

    private func releaseVideoThumbnailSlot() {
        while !waitingVideoThumbnailOrder.isEmpty {
            let id = waitingVideoThumbnailOrder.removeFirst()
            if let continuation = waitingVideoThumbnailSlots.removeValue(forKey: id) {
                continuation.resume(returning: true)
                return
            }
        }

        activeVideoThumbnailTasks = max(activeVideoThumbnailTasks - 1, 0)
    }

    private var isEvicting = false

    private func evictDiskIfNeeded() {
        guard !isEvicting else { return }
        isEvicting = true
        defer { isEvicting = false }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var files: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0

        for case let file as URL in enumerator {
            guard !file.hasDirectoryPath else { continue }
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            let size = values.fileSize ?? 0
            files.append((file, size, values.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > diskMaxBytes else { return }
        files.sort { $0.mtime < $1.mtime }

        let target = Int(Double(diskMaxBytes) * 0.75)
        for file in files {
            guard total > target else { break }
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }

}
