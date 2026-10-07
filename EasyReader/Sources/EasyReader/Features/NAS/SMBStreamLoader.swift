import AVFoundation
import UniformTypeIdentifiers

/// Bridges SMB range reads to AVPlayer via AVAssetResourceLoaderDelegate.
/// Usage: `SMBStreamLoader.makePlayerItem(client:remotePath:)` returns an AVPlayerItem
/// that streams directly from NAS — no full download needed.
final class SMBStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    /// Custom URL scheme that triggers the resource loader delegate.
    static let scheme = "smb-stream"

    static func supportsVideo(path: String) -> Bool {
        ["mp4", "mov", "m4v", "ts"].contains((path as NSString).pathExtension.lowercased())
    }

    private let client: any SMBRangeSource
    private let remotePath: String
    private let queue = DispatchQueue(label: "smb-stream", qos: .userInitiated)

    /// Cached file size — fetched once on first request.
    private var cachedFileSize: Int64?

    private init(client: any SMBRangeSource, remotePath: String) {
        self.client = client
        self.remotePath = remotePath
    }

    // MARK: - Public factory

    /// Creates an AVURLAsset that streams from NAS. The loader is retained on the asset.
    static func makeAsset(client: any SMBRangeSource, remotePath: String) -> AVURLAsset {
        let loader = SMBStreamLoader(client: client, remotePath: remotePath)

        let encoded = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        let url = URL(string: "\(scheme)://nas\(encoded)")!

        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // Retain the loader for the lifetime of the asset
        objc_setAssociatedObject(asset, "SMBStreamLoader", loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    /// Creates an AVPlayerItem that streams from NAS via SMB range reads.
    static func makePlayerItem(client: any SMBRangeSource, remotePath: String) -> AVPlayerItem {
        let asset = makeAsset(client: client, remotePath: remotePath)
        return AVPlayerItem(asset: asset)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        Task {
            await handleRequest(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Nothing to cancel — SMB reads are short-lived
    }

    // MARK: - Request handling

    private func handleRequest(_ request: AVAssetResourceLoadingRequest) async {
        do {
            // Resolve file size once
            if cachedFileSize == nil {
                cachedFileSize = try await client.fileSize(at: remotePath)
            }
            guard let fileSize = cachedFileSize, fileSize > 0 else {
                request.finishLoading(with: SMBStreamError.emptyFile)
                return
            }

            // Content information request (type + length)
            if let info = request.contentInformationRequest {
                let ext = (remotePath as NSString).pathExtension.lowercased()
                let contentType = UTType(filenameExtension: ext)?.identifier ?? "public.data"
                info.contentType = contentType
                info.contentLength = fileSize
                info.isByteRangeAccessSupported = true
            }

            // Data request (actual bytes)
            if let dataReq = request.dataRequest {
                let offset = UInt64(dataReq.requestedOffset)
                let length = Int(dataReq.requestedLength)

                // Read in chunks to avoid huge single reads
                let chunkSize = 512 * 1024  // 512 KB per read
                var bytesRead = 0

                while bytesRead < length {
                    guard !request.isCancelled else { return }

                    let remaining = length - bytesRead
                    let readLen = min(remaining, chunkSize)
                    let readOffset = offset + UInt64(bytesRead)

                    // Clamp to file size
                    guard readOffset < UInt64(fileSize) else { break }
                    let clampedLen = min(readLen, Int(UInt64(fileSize) - readOffset))
                    guard clampedLen > 0 else { break }

                    let data = try await client.readRange(at: remotePath, offset: readOffset, length: clampedLen)
                    dataReq.respond(with: data)
                    NotificationCenter.default.post(
                        name: VideoNetworkSpeedEvent.smbStreamBytesRead,
                        object: self,
                        userInfo: [
                            VideoNetworkSpeedEvent.pathKey: remotePath,
                            VideoNetworkSpeedEvent.bytesKey: data.count
                        ]
                    )
                    bytesRead += data.count

                    // If we got less than requested, file is exhausted
                    if data.count < clampedLen { break }
                }
            }

            request.finishLoading()
        } catch {
            request.finishLoading(with: error)
        }
    }
}

private enum SMBStreamError: LocalizedError {
    case emptyFile
    var errorDescription: String? { "文件为空" }
}
