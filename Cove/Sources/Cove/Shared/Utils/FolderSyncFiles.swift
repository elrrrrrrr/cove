import Foundation
import CryptoKit

/// All network-file-provider access and bounded disk I/O stays off MainActor.
actor FolderSyncFiles {
    struct Result: Sendable { let data: Data; let localData: Data; let conflicts: Bool }
    private struct Fingerprint { let size: Int; let modified: Date?; let hash: String }
    private var hashes: [String: Fingerprint] = [:]
    private let maximumSnapshot = 64 * 1024 * 1024
    private let maximumFile: Int64 = 100 * 1024 * 1024 * 1024

    private func hash(_ url: URL, progress: ((Int64, Int64) -> Void)? = nil) throws -> String {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              Int64(info.fileSize ?? 0) <= maximumFile else { throw ReaderSafetyError.message("同步文件不是普通文件或超过 100 GB") }
        if let cached = hashes[url.path], cached.size == info.fileSize, cached.modified == info.contentModificationDate {
            progress?(Int64(cached.size), Int64(cached.size)); return cached.hash
        }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256(); var count: Int64 = 0
        let total = Int64(info.fileSize ?? 0)
        var lastReport = ContinuousClock.now
        progress?(0, total)
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); count += Int64(chunk.count)
            guard count <= maximumFile else { throw ReaderSafetyError.message("同步文件超过 100 GB") }
            digest.update(data: chunk)
            if lastReport.duration(to: .now) >= .milliseconds(150) {
                progress?(count, total); lastReport = .now
            }
        }
        progress?(count, total)
        let result = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard after.fileSize == info.fileSize, after.contentModificationDate == info.contentModificationDate else {
            throw ReaderSafetyError.message("文件正在变化，稍后重试")
        }
        if hashes.count >= 512 { hashes.removeAll(keepingCapacity: true) }
        hashes[url.path] = Fingerprint(size: info.fileSize ?? 0, modified: info.contentModificationDate, hash: result)
        return result
    }
    private func coordinated<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Swift.Result<T, Error>?
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { coordinatedURL in result = Swift.Result { try body(coordinatedURL) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinatedURL in result = Swift.Result { try body(coordinatedURL) } }
        }
        if let error { throw error }
        guard let result else { throw ReaderSafetyError.message("无法访问同步文件夹") }
        return try result.get()
    }
    private func document(_ url: URL) throws -> Data? {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw ReaderSafetyError.message("云端备份尚未下载，稍后重试")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A not-yet-downloaded ubiquitous item is not an empty/new library.
            if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw ReaderSafetyError.message("云端备份尚未下载，稍后重试")
            }
            return nil
        }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= maximumSnapshot else {
            throw ReaderSafetyError.message("云端备份文件无效或超过 64 MB")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumSnapshot else { throw ReaderSafetyError.message("云端备份超过 64 MB") }
        return data
    }
    private func safe(_ path: String, root: URL) throws -> URL {
        guard !path.split(separator: "/").contains(".."),
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ReaderSafetyError.message("同步目录不允许路径穿越或符号链接")
        }
        return try ReaderContainedPath.resolve(path, under: root)
    }
    private func cloudFile(_ hash: String, root: URL) throws -> URL {
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ReaderSafetyError.message("文件校验值无效") }
        return try safe("Files/\(hash)", root: root)
    }
    private func copy(_ source: URL, to destination: URL, expected: String, progress: ((Int64, Int64) -> Void)? = nil, verifying: ((Int64, Int64) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: staged) }
        let sourceInfo = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard sourceInfo.isRegularFile == true, sourceInfo.isSymbolicLink != true,
              Int64(sourceInfo.fileSize ?? 0) <= maximumFile else { throw ReaderSafetyError.message("同步源文件无效或过大") }
        let total = Int64(sourceInfo.fileSize ?? 0)
        guard fm.createFile(atPath: staged.path, contents: nil) else { throw ReaderSafetyError.message("无法创建同步临时文件") }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: staged)
        defer { try? input.close(); try? output.close() }
        var bytes: Int64 = 0, lastReport = ContinuousClock.now
        progress?(0, total)
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(chunk.count)
            guard bytes <= maximumFile else { throw ReaderSafetyError.message("同步文件超过 100 GB") }
            try output.write(contentsOf: chunk)
            if lastReport.duration(to: .now) >= .milliseconds(150) {
                progress?(bytes, total); lastReport = .now
            }
        }
        try output.synchronize(); try output.close()
        progress?(bytes, total)
        guard try hash(staged, progress: verifying) == expected else { throw ReaderSafetyError.message("文件校验失败，已保留原文件") }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else { try fm.moveItem(at: staged, to: destination) }
    }

    func synchronize(local: Data, baseline: Data?, folder: URL, dataRoot: URL, recovery: URL, progress: @escaping @Sendable (FolderSyncProgress) -> Void = { _ in }) throws -> Result {
        progress(.init(phase: "准备本地备份"))
        var backup = try ConfigBackup.decode(local)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try local.write(to: recovery.appendingPathComponent("Before-Sync.json"), options: .atomic)
        // Fingerprint and upload only immutable model snapshots, not database/WAL files.
        if var offline = backup.offlineItems {
            let fileCount = offline.count
            for index in offline.indices {
                let item = offline[index]
                let fileName = item.title
                let report: @Sendable (String, Int64?, Int64?) -> Void = { phase, bytes, total in
                    progress(.init(phase: phase, fileName: fileName, fileNumber: index + 1, fileCount: fileCount,
                        completedBytes: bytes, totalBytes: total))
                }
                report("检查离线文件", nil, nil)
                if item.fileType == .web && item.localPath.isEmpty { continue }
                let source = try safe(item.localPath, root: dataRoot)
                if FileManager.default.fileExists(atPath: source.path) {
                    let digest = try hash(source) { report("校验本机文件", $0, $1) }
                    let destination = try cloudFile(digest, root: folder)
                    report("等待云盘文件就绪", nil, nil)
                    try coordinated(destination, writing: true) { url in
                        if try !FileManager.default.fileExists(atPath: url.path) || hash(url, progress: { report("校验云盘文件", $0, $1) }) != digest {
                            try copy(source, to: url, expected: digest, progress: { report("写入云盘文件", $0, $1) }, verifying: { report("校验写入结果", $0, $1) })
                        }
                    }
                    offline[index].contentSHA256 = digest
                } else {
                    // Keep the known cloud attachment if this device has not downloaded it.
                    let old = try baseline.map(ConfigBackup.decode)?.offlineItems?.first { $0.id == item.id }
                    offline[index].contentSHA256 = old?.contentSHA256
                    guard old?.contentSHA256 != nil else { throw ReaderSafetyError.message("离线文件缺失，暂不覆盖云端数据") }
                }
            }
            backup.offlineItems = offline
        }
        let prepared = try backup.json()
        guard prepared.count <= maximumSnapshot else { throw ReaderSafetyError.message("备份超过 64 MB，请减少封面数据") }
        progress(.init(phase: "读取云盘配置目录"))
        let output = try coordinated(folder, writing: true) { root in
            try synchronizeDocuments(prepared: prepared, baseline: baseline, root: root, recovery: recovery, progress: progress)
        }
        let merged = try ConfigBackup.decode(output.data)
        let incoming = merged.offlineItems ?? []
        let fileCount = incoming.count
        for (index, item) in incoming.enumerated() {
            let fileName = item.title
            let report: @Sendable (String, Int64?, Int64?) -> Void = { phase, bytes, total in
                progress(.init(phase: phase, fileName: fileName, fileNumber: index + 1, fileCount: fileCount,
                    completedBytes: bytes, totalBytes: total))
            }
            guard let digest = item.contentSHA256 else {
                if item.fileType == .web && item.localPath.isEmpty { continue }
                throw ReaderSafetyError.message("云端离线文件缺少校验值，暂不恢复不完整记录")
            }
            let destination = try safe(item.localPath, root: dataRoot)
            if FileManager.default.fileExists(atPath: destination.path), try hash(destination, progress: { report("校验本机文件", $0, $1) }) == digest { continue }
            let source = try cloudFile(digest, root: folder)
            report("等待云盘离线文件就绪", nil, nil)
            try coordinated(source, writing: false) { url in
                if FileManager.default.fileExists(atPath: destination.path) {
                    let archive = recovery.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: destination, to: archive)
                }
                try copy(url, to: destination, expected: digest, progress: { report("取回离线文件", $0, $1) }, verifying: { report("校验取回结果", $0, $1) })
            }
        }
        progress(.init(phase: "文件处理完成，准备保存记录"))
        return output
    }
    func readBaseline(_ url: URL) throws -> Data? {
        guard let bytes = try document(url) else { return nil }
        _ = try ConfigBackup.decode(bytes)
        return bytes
    }
    func saveBaseline(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private extension FolderSyncFiles {
    struct PackageSnapshot {
        var data: Data
        var documents: [String: Data]
        var sitePaths: [String: String]
        var needsPublication: Bool
    }

    func readPackage(root: URL, baseline: Data?) throws -> PackageSnapshot? {
        let metadataURL = try safe(FolderSyncPackage.appDataName, root: root)
        guard let metadata = try document(metadataURL) else {
            let directory = try safe(FolderSyncPackage.sitesDirectory, root: root)
            let containsSites = try FileManager.default.fileExists(atPath: directory.path)
                && !FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty
            let favoriteURL = try safe(FolderSyncPackage.favoritesName, root: root)
            if baseline != nil || FileManager.default.fileExists(atPath: favoriteURL.path) || containsSites {
                throw ReaderSafetyError.message("app-data.json 已移走或尚未下载，暂不覆盖云端目录")
            }
            return nil
        }
        guard let favorites = try document(safe(FolderSyncPackage.favoritesName, root: root)) else {
            throw ReaderSafetyError.message("favorites.json 尚未下载或已移走，暂不覆盖")
        }
        var documents = [FolderSyncPackage.appDataName: metadata, FolderSyncPackage.favoritesName: favorites]
        var sitePaths: [String: String] = [:]
        var bytes = metadata.count + favorites.count
        guard bytes <= maximumSnapshot else { throw ReaderSafetyError.message("配置目录超过 64 MB") }
        let sites = try safe(FolderSyncPackage.sitesDirectory, root: root)
        if FileManager.default.fileExists(atPath: sites.path) {
            guard try sites.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw ReaderSafetyError.message("sites 必须是文件夹")
            }
            let files = try FileManager.default.contentsOfDirectory(at: sites, includingPropertiesForKeys: nil)
            guard files.count <= 1000 else { throw ReaderSafetyError.message("站点目录文件过多") }
            for file in files {
                if file.lastPathComponent.hasPrefix("."), file.lastPathComponent.hasSuffix(".site.icloud") {
                    let name = String(file.lastPathComponent.dropFirst().dropLast(7))
                    try? FileManager.default.startDownloadingUbiquitousItem(at: safe("sites/\(name)", root: root))
                    throw ReaderSafetyError.message("站点文件尚未下载，稍后重试")
                }
                guard file.pathExtension == "site" else { continue }
                let path = "sites/\(file.lastPathComponent)"
                guard let data = try document(safe(path, root: root)), let text = String(data: data, encoding: .utf8) else {
                    throw ReaderSafetyError.message("站点文件尚未下载或不是 UTF-8 文本")
                }
                let definition = try SiteDefinition.decode(text)
                guard sitePaths[definition.id] == nil else { throw ReaderSafetyError.message("站点 id 重复") }
                sitePaths[definition.id] = path; documents[path] = data; bytes += data.count
                guard bytes <= maximumSnapshot else { throw ReaderSafetyError.message("配置目录超过 64 MB") }
            }
        }
        let snapshot = try FolderSyncPackage.assemble(documents, baseline: baseline)
        let canonical = try FolderSyncPackage.documents(snapshot, sitePaths: sitePaths)
        let normalize = try canonical.contains { path, bytes in
            guard let existing = documents[path] else { return true }
            return try !FolderSyncPackage.equivalentDocument(path, existing, bytes)
        }
        return PackageSnapshot(data: snapshot, documents: documents, sitePaths: sitePaths,
            needsPublication: normalize)
    }

    func synchronizeDocuments(prepared: Data, baseline: Data?, root: URL, recovery: URL,
                              progress: @escaping @Sendable (FolderSyncProgress) -> Void) throws -> Result {
        let previous = try readPackage(root: root, baseline: baseline)
        var remote = previous?.data
        var versions: [(path: String, bytes: Data, version: NSFileVersion)] = []
        if let previous {
            // Resolve provider conflicts using the same snapshot merge, retaining original files.
            for path in previous.documents.keys.sorted() {
                let url = try safe(path, root: root)
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                    guard let bytes = try document(version.url) else { throw ReaderSafetyError.message("云盘冲突版本尚未下载") }
                    var documents = previous.documents; documents[path] = bytes
                    let alternative = try FolderSyncPackage.assemble(documents, baseline: baseline)
                    remote = try FolderSyncMerge.merge(local: remote ?? previous.data, remote: alternative, baseline: baseline).data
                    versions.append((path, bytes, version))
                }
            }
        }
        progress(.init(phase: "合并站点、收藏和应用数据"))
        let result: FolderSyncMerge.Result
        if let remote { result = try FolderSyncMerge.merge(local: prepared, remote: remote, baseline: baseline) }
        else { result = .init(data: prepared, hasConflicts: false) }
        _ = try ConfigBackup.decode(result.data)
        let conflicts = result.hasConflicts || !versions.isEmpty
        if conflicts, let previous {
            let archive = try safe("Conflicts/\(UUID().uuidString)", root: root)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try prepared.write(to: archive.appendingPathComponent("Local.json"), options: .atomic)
            try previous.data.write(to: archive.appendingPathComponent("Cloud.json"), options: .atomic)
            for (index, item) in versions.enumerated() {
                let destination = try safe("Provider-\(index)/\(item.path)", root: archive)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try item.bytes.write(to: destination, options: .atomic)
            }
        }
        let mustPublish = try previous == nil || previous!.needsPublication || !versions.isEmpty
            || !FolderSyncMerge.equivalent(result.data, previous!.data)
        if mustPublish {
            let desired = try FolderSyncPackage.documents(result.data, sitePaths: previous?.sitePaths ?? [:])
            try publish(desired, previous: previous, root: root, progress: progress)
            let verified = try readPackage(root: root, baseline: baseline)
            guard let verified, try FolderSyncMerge.equivalent(verified.data, result.data) else {
                throw ReaderSafetyError.message("分文件写入后的校验失败，旧数据已保留")
            }
        }
        for item in versions { item.version.isResolved = true }
        return Result(data: result.data, localData: prepared, conflicts: conflicts)
    }

    func publish(_ desired: [String: Data], previous: PackageSnapshot?, root: URL,
                 progress: @escaping @Sendable (FolderSyncProgress) -> Void) throws {
        var original = previous?.documents ?? [:]
        for path in desired.keys where original[path] == nil {
            if let existing = try document(safe(path, root: root)) { original[path] = existing }
        }
        let changed = try desired.keys.filter { path in
            guard let old = original[path] else { return true }
            return try !FolderSyncPackage.equivalentDocument(path, old, desired[path]!)
        }.sorted { left, right in
            if left == FolderSyncPackage.appDataName { return false }
            if right == FolderSyncPackage.appDataName { return true }
            return left < right
        }
        let removed = original.keys.filter { desired[$0] == nil }
        let archive = try safe("Backups/\(UUID().uuidString)", root: root)
        // Save previous bytes before touching active documents; comments and user edits survive.
        for path in changed + removed {
            guard let data = original[path] else { continue }
            let target = try safe(path, root: archive)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        var written: [String] = [], erased: [String] = []
        do {
            for (index, path) in changed.enumerated() {
                let bytes = desired[path]!
                guard bytes.count <= maximumSnapshot else { throw ReaderSafetyError.message("配置文件超过 64 MB") }
                progress(.init(phase: "写入分文件配置", fileName: path, fileNumber: index + 1, fileCount: changed.count))
                let target = try safe(path, root: root)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target, options: .atomic); written.append(path)
            }
            for path in removed {
                try FileManager.default.removeItem(at: safe(path, root: root)); erased.append(path)
            }
        } catch {
            for path in written + erased {
                let target = try safe(path, root: root)
                if let old = original[path] { try? old.write(to: target, options: .atomic) }
                else { try? FileManager.default.removeItem(at: target) }
            }
            throw error
        }
    }
}
