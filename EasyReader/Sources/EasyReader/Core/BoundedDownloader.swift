import Foundation

/// Foreground downloads stream to disk. The delegate cancels oversized responses while
/// they are arriving, validates HTTP before publication, and owns temporary-file cleanup.
enum BoundedDownloader {
    static func download(_ request: URLRequest, maxBytes: Int64) async throws -> URL {
        let operation = DownloadOperation(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start(request, continuation: $0) }
        } onCancel: { operation.cancel() }
    }
}

private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var resultURL: URL?
    private var failure: Error?

    init(maxBytes: Int64) { self.maxBytes = maxBytes }
    func start(_ request: URLRequest, continuation: CheckedContinuation<URL, Error>) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        let cancel = lock.withLock {
            self.continuation = continuation; self.session = session; self.task = task
            return cancelled
        }
        if cancel { task.cancel(); finish(error: CancellationError()) }
        else { task.resume() }
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            lock.withLock { failure = CoveError.message("下载文件超过容量限制") }
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw CoveError.message("下载失败：HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= maxBytes else { throw CoveError.message("下载文件超过容量限制") }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("cove-transfer-" + UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: target)
            lock.withLock { resultURL = target }
        } catch { lock.withLock { failure = error } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error: error) }
    private func finish(error: Error?) {
        let state = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?, Error?, URLSession?) in
            let value = (continuation, resultURL, failure ?? (cancelled ? CancellationError() : error), session)
            continuation = nil; resultURL = nil; session = nil; task = nil
            return value
        }
        state.3?.invalidateAndCancel()
        guard let continuation = state.0 else { if let file = state.1 { try? FileManager.default.removeItem(at: file) }; return }
        if let error = state.2 {
            if let file = state.1 { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: error)
        } else if let file = state.1 { continuation.resume(returning: file) }
        else { continuation.resume(throwing: CoveError.message("下载没有产生文件")) }
    }
}
