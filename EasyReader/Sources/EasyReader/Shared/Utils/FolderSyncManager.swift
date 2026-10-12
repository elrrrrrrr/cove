import Foundation
import SwiftData
import CryptoKit

@Observable @MainActor
final class FolderSyncManager {
    static let shared = FolderSyncManager()
    private(set) var folderName: String?
    private(set) var isSyncing = false
    private(set) var message = "尚未连接文件夹"
    private(set) var errorDetails: String?
    private(set) var lastSync: Date?
    private(set) var hasConflicts = false
    var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.autoKey) }
    }
    private static let bookmarkKey = "folderSync.bookmark"
    private static let autoKey = "folderSync.automatic"
    private let files = FolderSyncFiles()
    private var context: ModelContext?
    private var pending: Task<Void, Never>?
    private var isApplying = false
    private var foreground = false
    private var foregroundToken: UUID?
    private(set) var isConnected = false

    private init() {
        automatic = UserDefaults.standard.object(forKey: Self.autoKey) == nil || UserDefaults.standard.bool(forKey: Self.autoKey)
        isConnected = UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
        if isConnected {
            do { folderName = try resolveFolder().lastPathComponent; message = "待同步" }
            catch { message = "请重新选择文件夹"; errorDetails = error.localizedDescription }
        }
    }
    private func resolveFolder() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            throw ReaderSafetyError.message("请先选择同步文件夹")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            UserDefaults.standard.set(try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: Self.bookmarkKey)
        }
        return url
    }
    func connect(_ url: URL) async {
        guard !isSyncing else { return }
        errorDetails = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw ReaderSafetyError.message("请选择普通文件夹") }
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            isConnected = true
            folderName = url.lastPathComponent; message = "待同步"; lastSync = nil; hasConflicts = false
            await synchronize()
        } catch { message = "连接失败"; errorDetails = error.localizedDescription }
    }
    func disconnect() {
        guard !isSyncing else { return }
        pending?.cancel(); pending = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        isConnected = false
        errorDetails = nil
        folderName = nil; lastSync = nil; hasConflicts = false; message = "尚未连接文件夹"
    }
    func requestSync() {
        guard automatic, foreground, context != nil, isConnected, !isApplying, !isSyncing else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.synchronize()
        }
    }
    func runWhileActive(context: ModelContext) async {
        let token = UUID()
        self.context = context; foreground = true; foregroundToken = token
        defer {
            if foregroundToken == token { foreground = false; foregroundToken = nil; pending?.cancel() }
        }
        while !Task.isCancelled {
            if automatic { await synchronize() }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
    func synchronize() async {
        guard !isSyncing, let context, isConnected else { return }
        isSyncing = true; message = "同步中…"; errorDetails = nil
        defer { isSyncing = false }
        var scopedFolder: URL?
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }
        do {
            let folder = try resolveFolder()
            if folder.startAccessingSecurityScopedResource() { scopedFolder = folder }
            folderName = folder.lastPathComponent
            let identifier = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let stateRoot = LocalAppStorage.config.appendingPathComponent("FolderSync/\(identifier)")
            let baselineURL = stateRoot.appendingPathComponent("Baseline.json")
            let recovery = stateRoot.appendingPathComponent("Recovery/Latest")
            try context.save()
            let original = try ConfigBackup.captureAll(context: context).json()
            let baseline = try await files.readBaseline(baselineURL)
            let result = try await files.synchronize(local: original, baseline: baseline, folder: folder,
                dataRoot: LocalAppStorage.data, recovery: recovery)
            // Merge user edits made while file-provider I/O was suspended, before applying.
            var current = try ConfigBackup.captureAll(context: context)
            let initial = try ConfigBackup.decode(original)
            let prepared = try ConfigBackup.decode(result.localData)
            if var items = current.offlineItems {
                for index in items.indices {
                    let item = items[index]
                    if let previous = initial.offlineItems?.first(where: { $0.id == item.id }),
                       previous.localPath == item.localPath,
                       previous.fileSizeBytes == item.fileSizeBytes {
                        items[index].contentSHA256 = prepared.offlineItems?.first { $0.id == item.id }?.contentSHA256
                    }
                }
                current.offlineItems = items
            }
            let currentData = try current.json()
            let final = try FolderSyncMerge.merge(local: currentData, remote: result.data, baseline: result.localData)
            let merged = try ConfigBackup.decode(final.data)
            if !(try FolderSyncMerge.equivalent(currentData, final.data)) {
                if final.hasConflicts { try await files.saveBaseline(currentData, at: recovery.appendingPathComponent("During-Sync.json")) }
                isApplying = true
                defer { isApplying = false }
                try merged.applySynchronized(to: context)
            }
            try await files.saveBaseline(result.data, at: baselineURL)
            lastSync = Date(); hasConflicts = result.conflicts || final.hasConflicts
            message = "同步完成"
            if !(try FolderSyncMerge.equivalent(final.data, result.data)) { requestSync() }
        } catch is CancellationError { message = "同步已暂停" }
        catch { message = "同步失败"; errorDetails = error.localizedDescription }
    }
}
