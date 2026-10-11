import Foundation

protocol OfflineDownloadSource: Sendable {
    var cacheIdentity: String { get }
    func download(remotePath: String, to: URL, maxBytes: Int64, progress: @Sendable @escaping (Double) -> Void) async throws
}

struct OfflineTransferResult: Sendable { let file: URL; let path: String; let bytes: Int64 }

/// Delegate work stays off MainActor; only throttled progress crosses into the UI.
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int64
    private let publish: @Sendable (Double) -> Void
    private var failure: Error?
    private var lastProgress = 0.0
    private var lastTime = Date.distantPast
    init(limit: Int64, publish: @escaping @Sendable (Double) -> Void) { self.limit = limit; self.publish = publish }
    func report(_ fraction: Double) {
        let progress = max(0, min(1, fraction)), now = Date()
        let shouldPublish = lock.withLock {
            guard progress > lastProgress, progress - lastProgress >= 0.01,
                  progress >= 1 || now.timeIntervalSince(lastTime) >= 0.1 else { return false }
            lastProgress = progress; lastTime = now; return true
        }
        if shouldPublish { publish(progress) }
    }
    func check() throws { if let error = lock.withLock({ failure }) { throw error } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let error: Error?
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200...299).contains(code) { error = OfflineTransferError.status(code) }
        else if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { error = SMBError.tooLarge(limit) }
        else { error = nil }
        if let error { lock.withLock { failure = error }; downloadTask.cancel(); return }
        if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}

enum OfflineTransferError: LocalizedError {
    case invalidURL, status(Int)
    var errorDescription: String? {
        switch self { case .invalidURL: "下载地址必须是 HTTP 或 HTTPS"; case .status(let code): "下载失败（HTTP \(code)）" }
    }
}

enum OfflineTransfer {
    static func run(_ download: DownloadManager.Download, attempt: UUID, files: OfflineFiles, session: URLSession,
                    source: (any OfflineDownloadSource)?, limit: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> OfflineTransferResult {
        try Task.checkCancellation()
        let file = try files.destination(id: download.id, attempt: attempt, isNAS: download.isNAS, source: download.sourceURL, type: download.fileType)
        do {
            let observer = DownloadProgress(limit: limit, publish: progress)
            if download.isNAS {
                guard let source else { throw SMBError.notConnected }
                try await source.download(remotePath: download.sourceURL, to: file, maxBytes: limit) { observer.report($0) }
            } else {
                guard let url = URL(string: download.sourceURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw OfflineTransferError.invalidURL }
                var request = URLRequest(url: url); request.timeoutInterval = 60
                let temp: URL, response: URLResponse
                do { (temp, response) = try await session.download(for: request, delegate: observer) }
                catch { try observer.check(); throw error }
                defer { try? FileManager.default.removeItem(at: temp) }
                try observer.check()
                guard let http = response as? HTTPURLResponse else { throw OfflineTransferError.invalidURL }
                guard (200...299).contains(http.statusCode) else { throw OfflineTransferError.status(http.statusCode) }
                let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard Int64(size) <= limit else { throw SMBError.tooLarge(limit) }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temp, to: file)
            }
            try Task.checkCancellation()
            let bytes = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard bytes <= limit else { throw SMBError.tooLarge(limit) }
            return OfflineTransferResult(file: file, path: try files.relativePath(file), bytes: bytes)
        } catch { files.discardAttempt(file: file); throw error }
    }
}
