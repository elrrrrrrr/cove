import Foundation

/// Manages offline downloads (HTTP + NAS), with a concurrent queue and progress tracking.
/// `@Observable @MainActor` singleton with `pendingPersist` for SwiftData writes.
@Observable
@MainActor
final class DownloadManager {

    // MARK: - Download item

    struct Download: Identifiable, Sendable {
        let id: UUID
        let title: String
        let sourceURL: String          // web URL or NAS remote path
        let fileType: FileType
        let thumbnailData: Data?
        let isNAS: Bool
        var state: State = .pending
        var progress: Double = 0
        var localPath: String = ""
        var fileSizeBytes: Int64 = 0

        enum State: Equatable, Sendable {
            case pending
            case downloading
            case completed
            case failed(String)

            var isTerminal: Bool {
                switch self {
                case .completed, .failed: true
                default: false
                }
            }
        }

        init(title: String, sourceURL: String, fileType: FileType,
             thumbnailData: Data? = nil, isNAS: Bool = false) {
            self.id = UUID()
            self.title = title
            self.sourceURL = sourceURL
            self.fileType = fileType
            self.thumbnailData = thumbnailData
            self.isNAS = isNAS
        }
    }

    // MARK: - Singleton

    static let shared = DownloadManager()

    // MARK: - State

    var downloads: [Download] = []
    var pendingPersist: [Download] = []

    /// O(1) lookup from download ID → array index. Updated on every mutation.
    private var indexByID: [UUID: Int] = [:]

    var activeCount: Int {
        downloads.filter { $0.state == .downloading }.count
    }

    private let maxConcurrent = 2
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var smbClient: SMBClient?
    /// Last progress value sent per download — used to throttle updates (>1% change).
    private var lastReportedProgress: [UUID: Double] = [:]

    private init() {}

    // MARK: - Public API

    func add(title: String, sourceURL: String, fileType: FileType,
             thumbnailData: Data? = nil, isNAS: Bool = false) {
        // Skip if already queued for this URL
        guard !downloads.contains(where: {
            $0.sourceURL == sourceURL && !$0.state.isTerminal
        }) else { return }

        let dl = Download(title: title, sourceURL: sourceURL,
                          fileType: fileType, thumbnailData: thumbnailData, isNAS: isNAS)
        downloads.insert(dl, at: 0)
        rebuildIndex()
        processQueue()
    }

    func cancel(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        lastReportedProgress.removeValue(forKey: id)
        downloads.removeAll { $0.id == id }
        rebuildIndex()
        processQueue()
    }

    func retry(id: UUID) {
        guard let idx = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[idx].state = .pending
        downloads[idx].progress = 0
        processQueue()
    }

    func remove(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        lastReportedProgress.removeValue(forKey: id)
        downloads.removeAll { $0.id == id }
        rebuildIndex()
    }

    func configureSMB(client: SMBClient) {
        self.smbClient = client
    }

    func drainPendingPersist() -> [Download] {
        let batch = pendingPersist
        pendingPersist.removeAll()
        return batch
    }

    // MARK: - Index management

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (i, dl) in downloads.enumerated() {
            indexByID[dl.id] = i
        }
    }

    private func indexOf(_ id: UUID) -> Int? {
        if let i = indexByID[id], i < downloads.count, downloads[i].id == id { return i }
        // Fallback: rebuild if stale
        rebuildIndex()
        return indexByID[id]
    }

    // MARK: - Queue processing

    private func processQueue() {
        while activeCount < maxConcurrent,
              let idx = downloads.firstIndex(where: { $0.state == .pending }) {
            startDownload(at: idx)
        }
    }

    private func startDownload(at idx: Int) {
        downloads[idx].state = .downloading
        let dl = downloads[idx]

        let task = Task {
            if dl.isNAS {
                await downloadNAS(id: dl.id)
            } else {
                await downloadHTTP(id: dl.id)
            }
        }
        activeTasks[dl.id] = task
    }

    // MARK: - HTTP download

    private func downloadHTTP(id: UUID) async {
        guard let idx = downloads.firstIndex(where: { $0.id == id }),
              let url = URL(string: downloads[idx].sourceURL) else {
            markFailed(id: id, message: "无效的 URL")
            return
        }

        let filename = "\(id.uuidString)_\(url.lastPathComponent)"
        let dest = FileManager.default.offlineWebDirectory
            .appendingPathComponent(filename)

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.moveItem(at: tempURL, to: dest)

            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? Int64) ?? 0

            guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
            downloads[i].state = .completed
            downloads[i].localPath = dest.path
            downloads[i].fileSizeBytes = size
            downloads[i].progress = 1.0
            pendingPersist.append(downloads[i])
            activeTasks.removeValue(forKey: id)
            processQueue()
        } catch {
            markFailed(id: id, message: error.localizedDescription)
        }
    }

    // MARK: - NAS download

    private func downloadNAS(id: UUID) async {
        guard let client = smbClient,
              let idx = downloads.firstIndex(where: { $0.id == id }) else {
            markFailed(id: id, message: "NAS 未连接")
            return
        }

        let remotePath = downloads[idx].sourceURL
        let filename = URL(fileURLWithPath: remotePath).lastPathComponent
        let dest = FileManager.default.offlineNASDirectory
            .appendingPathComponent(filename)

        do {
            try await client.download(remotePath: remotePath, to: dest) { [weak self] pct in
                Task { @MainActor in
                    guard let self, let i = self.indexOf(id) else { return }
                    // Throttle: only update UI when progress changes by >1%
                    let last = self.lastReportedProgress[id] ?? 0
                    guard pct - last >= 0.01 || pct >= 1.0 else { return }
                    self.lastReportedProgress[id] = pct
                    self.downloads[i].progress = pct
                }
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? Int64) ?? 0

            guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
            downloads[i].state = .completed
            downloads[i].localPath = dest.path
            downloads[i].fileSizeBytes = size
            downloads[i].progress = 1.0
            pendingPersist.append(downloads[i])
            activeTasks.removeValue(forKey: id)
            processQueue()
        } catch {
            markFailed(id: id, message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func markFailed(id: UUID, message: String) {
        if let i = downloads.firstIndex(where: { $0.id == id }) {
            downloads[i].state = .failed(message)
        }
        activeTasks.removeValue(forKey: id)
        processQueue()
    }
}
