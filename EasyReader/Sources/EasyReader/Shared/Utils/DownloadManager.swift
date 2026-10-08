import Foundation

@Observable @MainActor final class DownloadManager {
    struct Download: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let sourceURL: String
        let fileType: FileType
        let thumbnailData: Data?
        let isNAS: Bool
        let sourceIdentity: String?
        var state: State = .pending
        var progress = 0.0
        var localPath = ""
        var fileSizeBytes: Int64 = 0
        enum State: Equatable, Sendable {
            case pending, downloading, completed, failed(String)
            var isTerminal: Bool { switch self { case .completed, .failed: true; default: false } }
        }
    }
    static let shared = DownloadManager()
    private(set) var downloads: [Download] = []
    private(set) var pendingPersist: [Download] = []
    private struct Attempt { let downloadID: UUID; let task: Task<Void, Never> }
    private var running: [UUID: Attempt] = [:]
    private var currentAttempt: [UUID: UUID] = [:]
    private var indexByID: [UUID: Int] = [:]
    private var sources: [UUID: any OfflineDownloadSource] = [:]
    private var smbClient: (any OfflineDownloadSource)?
    private let files: OfflineFiles
    private let session: URLSession
    private let limit: Int64
    private let maxConcurrent: Int
    private var clearing = false
    var activeCount: Int { running.count }

    init(files: OfflineFiles = .shared, session: URLSession = .shared, limit: Int64 = SMBFileRead.maxTemporaryBytes, maxConcurrent: Int = 2) {
        self.files = files; self.session = session; self.limit = limit; self.maxConcurrent = max(1, maxConcurrent)
    }
    @discardableResult func add(title: String, sourceURL: String, fileType: FileType, thumbnailData: Data? = nil, isNAS: Bool = false) -> UUID? {
        guard !clearing else { return nil }
        let identity = isNAS ? smbClient?.cacheIdentity : nil
        if let existing = downloads.first(where: { $0.sourceURL == sourceURL && $0.isNAS == isNAS && $0.sourceIdentity == identity && !$0.state.isTerminal }) { return existing.id }
        let item = Download(title: title, sourceURL: sourceURL, fileType: fileType, thumbnailData: thumbnailData, isNAS: isNAS, sourceIdentity: identity)
        if isNAS { sources[item.id] = smbClient }
        downloads.insert(item, at: 0); rebuildIndex(); processQueue(); return item.id
    }
    func cancel(id: UUID) {
        stop(id)
        downloads.removeAll { $0.id == id }; sources.removeValue(forKey: id)
        rebuildIndex(); processQueue()
    }
    func remove(id: UUID) { cancel(id: id) }
    func retry(id: UUID) {
        guard let index = indexByID[id], downloads[index].state != .completed else { return }
        stop(id)
        downloads[index].state = .pending; downloads[index].progress = 0
        downloads[index].localPath = ""; downloads[index].fileSizeBytes = 0
        processQueue()
    }
    private func stop(_ id: UUID) {
        if let attempt = currentAttempt.removeValue(forKey: id) { running[attempt]?.task.cancel() }
    }
    func configureSMB(client: any OfflineDownloadSource) {
        smbClient = client
        for download in downloads where download.isNAS && download.sourceIdentity == client.cacheIdentity && download.state != .downloading { sources[download.id] = client }
    }
    func drainPendingPersist() -> [Download] {
        let batch = pendingPersist, ids = Set(batch.map(\.id))
        pendingPersist.removeAll()
        downloads.removeAll { ids.contains($0.id) && $0.state == .completed }
        rebuildIndex(); return batch
    }
    func clear() async {
        clearing = true; currentAttempt.removeAll()
        let tasks = running.values.map(\.task)
        for task in tasks { task.cancel() }
        downloads.removeAll(); pendingPersist.removeAll(); sources.removeAll(); indexByID.removeAll()
        for task in tasks { await task.value }
        running.removeAll(); clearing = false
    }
    private func rebuildIndex() { indexByID = Dictionary(downloads.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first }) }
    private func processQueue() {
        guard !clearing else { return }
        while running.count < maxConcurrent, let item = downloads.first(where: { item in
            item.state == .pending && !running.values.contains(where: { $0.downloadID == item.id })
        }) { start(item) }
    }
    private func start(_ item: Download) {
        let attempt = UUID(), files = files, session = session, limit = limit, source = sources[item.id]
        currentAttempt[item.id] = attempt
        if let index = indexByID[item.id] { downloads[index].state = .downloading }
        let task = Task { [weak self] in
            let result: Result<OfflineTransferResult, Error>
            do {
                result = .success(try await OfflineTransfer.run(item, attempt: attempt, files: files, session: session, source: source, limit: limit) { [weak self] fraction in
                    Task { @MainActor in self?.progress(item.id, attempt: attempt, fraction: fraction) }
                })
            } catch { result = .failure(error) }
            guard let self else {
                if case .success(let output) = result { files.discardAttempt(file: output.file) }
                return
            }
            finish(item.id, attempt: attempt, result: result)
        }
        running[attempt] = Attempt(downloadID: item.id, task: task)
    }
    private func progress(_ id: UUID, attempt: UUID, fraction: Double) {
        guard currentAttempt[id] == attempt, let index = indexByID[id], downloads[index].state == .downloading else { return }
        downloads[index].progress = max(downloads[index].progress, min(fraction, 0.99))
    }
    private func finish(_ id: UUID, attempt: UUID, result: Result<OfflineTransferResult, Error>) {
        running.removeValue(forKey: attempt)
        defer { processQueue() }
        guard currentAttempt[id] == attempt, let index = indexByID[id] else {
            if case .success(let output) = result { let files = files; Task.detached(priority: .utility) { files.discardAttempt(file: output.file) } }
            return
        }
        currentAttempt.removeValue(forKey: id)
        switch result {
        case .success(let output):
            downloads[index].state = .completed; downloads[index].progress = 1
            downloads[index].localPath = output.path; downloads[index].fileSizeBytes = output.bytes
            pendingPersist.append(downloads[index]); sources.removeValue(forKey: id)
        case .failure(let error): downloads[index].state = .failed(error.localizedDescription)
        }
    }
}
