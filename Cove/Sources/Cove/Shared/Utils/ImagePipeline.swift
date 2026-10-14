import UIKit
import SwiftUI
import CryptoKit

struct ThumbnailRequest: Hashable, Sendable {
    let url: URL
    let referer: URL?
    let definitionID: String?
    let transform: SiteImageTransform?
    let sizing: ImageSizing
    let resourceID: String
    var cacheID: String { resourceID + "-" + sizing.cacheSuffix }

    init(url: URL, referer: URL? = nil, definitionID: String? = nil, sizing: ImageSizing = .thumbnail(512)) {
        self.url = url; self.referer = referer; self.definitionID = definitionID; self.sizing = sizing
        transform = SiteParserRegistry.imageTransform(for: url, referer: referer, definitionID: definitionID)
        let fields = [url.absoluteString, referer?.absoluteString ?? "", definitionID ?? "", transform?.key ?? "", transform?.iv ?? ""]
        let context = fields.map { "\($0.utf8.count):\($0)" }.joined()
        resourceID = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private init(_ source: ThumbnailRequest, sizing: ImageSizing) {
        url = source.url; referer = source.referer; definitionID = source.definitionID
        transform = source.transform; resourceID = source.resourceID; self.sizing = sizing
    }
    func resized(_ sizing: ImageSizing) -> Self { Self(self, sizing: sizing) }
}

/// Synchronous display cache; all variants share a decoded-byte budget.
final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private final class Entry: NSObject {
        let image: UIImage
        let savedAt = Date()
        init(_ image: UIImage) { self.image = image }
    }
    private let cache = NSCache<NSString, Entry>()
    let costLimit: Int
    private let ttl: TimeInterval
    init(costLimit: Int = 100 * 1024 * 1024, countLimit: Int = 300, ttl: TimeInterval = 3600) {
        self.costLimit = costLimit; self.ttl = ttl
        cache.totalCostLimit = costLimit; cache.countLimit = countLimit
    }
    func store(_ image: UIImage, forKey key: String) {
        let cost = ImageDecoder.cost(image)
        guard cost <= costLimit else { return }
        cache.setObject(Entry(image), forKey: key as NSString, cost: cost)
    }
    func image(forKey key: String) -> UIImage? {
        guard let value = cache.object(forKey: key as NSString) else { return nil }
        guard Date().timeIntervalSince(value.savedAt) <= ttl else { cache.removeObject(forKey: key as NSString); return nil }
        return value.image
    }
    func store(_ image: UIImage, for request: ThumbnailRequest) { store(image, forKey: request.cacheID) }
    func image(for request: ThumbnailRequest) -> UIImage? { image(forKey: request.cacheID) }
    func store(_ image: UIImage, for url: URL) { store(image, for: ThumbnailRequest(url: url)) }
    func image(for url: URL) -> UIImage? { image(for: ThumbnailRequest(url: url)) }
    func clear() { cache.removeAllObjects() }
}

actor ImagePipeline {
    static let shared = ImagePipeline()
    static let maximumEncodedBytes = 32 * 1024 * 1024
    private var memory = ByteLRUCache<String>(byteLimit: 24 * 1024 * 1024, countLimit: 150)
    private let sources = SharedTaskPool<String, Data>()
    private let images = SharedTaskPool<String, UIImage>()
    private let decoders = AsyncWorkLimiter(limit: 2)
    private let disk: DiskDataCache
    private let root: URL
    private let session: URLSession

    init(root: URL? = nil, session: URLSession? = nil) {
        let directory = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CoverCache", isDirectory: true)
        self.root = directory
        disk = DiskDataCache(root: directory, suffix: ".image", byteLimit: 500 * 1024 * 1024, ttl: 7 * 86400, entryByteLimit: Self.maximumEncodedBytes)
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.default
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    func image(for request: ThumbnailRequest) async -> UIImage? {
        guard ["http", "https", "data"].contains(request.url.scheme?.lowercased() ?? "") else { return nil }
        return await rendered(request, localFile: nil)
    }
    func image(at file: URL, sizing: ImageSizing) async -> UIImage? {
        guard file.isFileURL else { return nil }
        return await rendered(ThumbnailRequest(url: file, sizing: sizing), localFile: file)
    }
    private func rendered(_ request: ThumbnailRequest, localFile: URL?) async -> UIImage? {
        if let cached = ImageMemoryCache.shared.image(for: request) { return Task.isCancelled ? nil : cached }
        return await images.value(for: request.cacheID) {
            let data = localFile == nil ? await self.data(for: request) : nil
            guard localFile != nil || data != nil, !Task.isCancelled else { return nil }
            let image = await self.decoders.run {
                let work = Task.detached(priority: .userInitiated) {
                    if let localFile { return ImageDecoder.decode(file: localFile, sizing: request.sizing) }
                    return data.flatMap { ImageDecoder.decode($0, sizing: request.sizing) }
                }
                return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            }
            guard !Task.isCancelled else { return nil }
            if let image { ImageMemoryCache.shared.store(image, for: request) }
            return image
        }
    }
    func data(for url: URL, referer: URL? = nil, definitionID: String? = nil) async -> Data? {
        await data(for: ThumbnailRequest(url: url, referer: referer, definitionID: definitionID))
    }
    func data(for request: ThumbnailRequest) async -> Data? {
        if let cached = memory.value(for: request.resourceID) { return Task.isCancelled ? nil : cached }
        return await sources.value(for: request.resourceID) { await self.fetch(request) }
    }
    private func fetch(_ request: ThumbnailRequest) async -> Data? {
        let key = request.resourceID
        if let data = await disk.load(key), ImageDecoder.isImage(data), !Task.isCancelled {
            memory.insert(data, for: key); return data
        }
        if request.definitionID == nil, request.referer == nil {
            let oldHash = SHA256.hash(data: Data(request.url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            let files = [root.appendingPathComponent(oldHash + ".image"), Self.legacyFile(for: request.url, under: root)].compactMap { $0 }
            let root = self.root
            for file in files {
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    guard file.path.hasPrefix(root.path + "/"),
                          let contained = try? ReaderContainedPath.resolve(String(file.path.dropFirst(root.path.count + 1)), under: root),
                          let info = try? contained.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                          let size = info.fileSize, size <= Self.maximumEncodedBytes,
                          let saved = info.contentModificationDate, Date().timeIntervalSince(saved) <= 7 * 86400 else { return nil }
                    return try? Data(contentsOf: contained)
                }.value
                if let data, ImageDecoder.isImage(data), !Task.isCancelled { await persist(data, key: key); return data }
            }
        }
        let data: Data?
        if request.url.scheme == "data" {
            let parts = request.url.absoluteString.split(separator: ",", maxSplits: 1)
            data = parts.count == 2 && parts[1].utf8.count <= Self.maximumEncodedBytes * 4 / 3 + 4
                ? Data(base64Encoded: String(parts[1]), options: .ignoreUnknownCharacters) : nil
        } else {
            guard ["http", "https"].contains(request.url.scheme?.lowercased() ?? "") else { return nil }
            var http = URLRequest(url: request.url)
            http.timeoutInterval = 20
            let referer = request.referer ?? request.url
            http.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if var origin = URLComponents(url: referer, resolvingAgainstBaseURL: true) {
                origin.path = ""; origin.query = nil; origin.fragment = nil; origin.user = nil; origin.password = nil
                http.setValue(origin.string, forHTTPHeaderField: "Origin")
            }
            do {
                let (file, response) = try await session.download(for: http, delegate: ImageDownloadLimit())
                defer { try? FileManager.default.removeItem(at: file) }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= Self.maximumEncodedBytes else { return nil }
                data = try Data(contentsOf: file)
            } catch { return nil }
        }
        guard let data, !data.isEmpty, !Task.isCancelled else { return nil }
        let decoded: Data
        if ImageDecoder.isImage(data) { decoded = data }
        else if let transform = request.transform,
                let plain = SiteCrypto.decrypt(data, key: Data(transform.key.utf8), iv: Data(transform.iv.utf8)), ImageDecoder.isImage(plain) { decoded = plain }
        else { return nil }
        await persist(decoded, key: key)
        return Task.isCancelled ? nil : decoded
    }
    private func persist(_ data: Data, key: String) async {
        guard !Task.isCancelled else { return }
        memory.insert(data, for: key)
        await disk.store(data, for: key)
    }
    func clearAll() async {
        await images.clear(); await sources.clear()
        memory.clear(); ImageMemoryCache.shared.clear()
        await disk.clear()
    }
    func diskUsageBytes() async -> Int { await disk.usageBytes() }
    func encodedMemoryBytes() -> Int { memory.byteCount }

    static func legacyFile(for url: URL, under root: URL) -> URL? {
        guard let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return try? ReaderContainedPath.resolve(([host] + parts).joined(separator: "/"), under: root)
    }
}

private final class ImageDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > ImagePipeline.maximumEncodedBytes || totalBytesExpectedToWrite > ImagePipeline.maximumEncodedBytes { downloadTask.cancel() }
    }
}

struct CachedThumbnail: View {
    var placeholder: String = "photo"
    private let source: ThumbnailRequest?
    @Environment(\.displayScale) private var scale
    @State private var pixels = 512
    @State private var image: UIImage?

    init(url: URL?, placeholder: String = "photo", referer: URL? = nil, definitionID: String? = nil) {
        self.placeholder = placeholder
        source = url.map { ThumbnailRequest(url: $0, referer: referer, definitionID: definitionID) }
        _image = State(initialValue: source.flatMap { ImageMemoryCache.shared.image(for: $0) })
    }
    private var request: ThumbnailRequest? { source?.resized(.thumbnail(pixels)) }
    var body: some View {
        Color(.secondarySystemBackground)
            .overlay(alignment: .top) {
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(minWidth: 0, minHeight: 0).clipped() }
            }
            .overlay {
                if image == nil { Image(systemName: placeholder).font(.title2).foregroundStyle(.tertiary) }
            }
            .clipped()
            .onGeometryChange(for: Int.self) { [scale] proxy in ImageSizing.pixels(points: max(proxy.size.width, proxy.size.height), scale: scale) } action: { pixels = $0 }
            .task(id: request) {
                guard let request else { image = nil; return }
                let loaded = await ImagePipeline.shared.image(for: request)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.15)) { image = loaded }
            }
    }
}
