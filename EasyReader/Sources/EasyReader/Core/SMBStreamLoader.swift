import AVFoundation
import UniformTypeIdentifiers
import ObjectiveC

protocol RangeReader: Sendable {
    func size(path: String) async throws -> Int64
    func readRange(path: String, offset: UInt64, length: Int) async throws -> Data
}

private final class StreamRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
    init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
}

/// State and AVFoundation callbacks are serialized on queue; each request has cancellable work.
final class SMBStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let client: any RangeReader
    private let path: String
    private let queue = DispatchQueue(label: "dev.cove.smb-stream")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private init(client: any RangeReader, path: String) { self.client = client; self.path = path }

    static func playerItem(client: any RangeReader, path: String) throws -> AVPlayerItem {
        AVPlayerItem(asset: try asset(client: client, path: path))
    }
    static func asset(client: any RangeReader, path: String) throws -> AVURLAsset {
        let loader = SMBStreamLoader(client: client, path: path)
        var components = URLComponents(); components.scheme = "cove-smb"; components.host = "resource"; components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = components.url else { throw CoveError.message("流式资源地址无效") }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        objc_setAssociatedObject(asset, Unmanaged.passUnretained(asset).toOpaque(), loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(request), box = StreamRequest(request)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let size = try await client.size(path: path)
                try Task.checkCancellation()
                let bounds = await self.prepare(box, size: size)
                if let (start, end) = bounds {
                    var offset = start
                    while offset < end {
                        try Task.checkCancellation()
                        let data = try await client.readRange(path: path, offset: UInt64(offset), length: Int(min(512 * 1024, end - offset)))
                        guard !data.isEmpty else { break }
                        try Task.checkCancellation()
                        await self.respond(data, to: box)
                        offset += Int64(data.count)
                    }
                }
                await self.finish(box, error: nil)
            } catch is CancellationError { }
            catch { await self.finish(box, error: error) }
            self.queue.async { self.tasks.removeValue(forKey: key) }
        }
        return true
    }
    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    private func prepare(_ box: StreamRequest, size: Int64) async -> (Int64, Int64)? {
        await withCheckedContinuation { continuation in
            queue.async {
                let request = box.value
                if let info = request.contentInformationRequest {
                    info.contentLength = size; info.isByteRangeAccessSupported = true
                    info.contentType = UTType(filenameExtension: (self.path as NSString).pathExtension)?.identifier ?? UTType.data.identifier
                }
                if let data = request.dataRequest {
                    let start = max(data.currentOffset, data.requestedOffset)
                    let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
                    continuation.resume(returning: (max(0, start), max(0, end)))
                } else { continuation.resume(returning: nil) }
            }
        }
    }
    private func respond(_ data: Data, to box: StreamRequest) async {
        await withCheckedContinuation { continuation in
            queue.async { if !box.value.isCancelled { box.value.dataRequest?.respond(with: data) }; continuation.resume() }
        }
    }
    private func finish(_ box: StreamRequest, error: Error?) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if !box.value.isCancelled {
                    if let error { box.value.finishLoading(with: error) } else { box.value.finishLoading() }
                }
                continuation.resume()
            }
        }
    }
}
