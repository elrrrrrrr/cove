import Foundation
import SwiftData

/// One writable offline directory; legacy references are rebased during file migration.
struct OfflineFiles: Sendable {
    static let shared = OfflineFiles(dataRoot: LocalAppStorage.data,
        documentsRoot: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    let dataRoot: URL
    let documentsRoot: URL
    var root: URL { dataRoot.appendingPathComponent("Offline", isDirectory: true) }
    private var legacyRoot: URL { documentsRoot.appendingPathComponent("Offline", isDirectory: true) }

    private func suffix(_ path: String) -> String? {
        if path.hasPrefix("Offline/") { return String(path.dropFirst(8)) }
        for anchor in ["/Documents/Offline/", "/Library/Application Support/Cove/data/Offline/"] {
            if let range = path.range(of: anchor) { return String(path[range.upperBound...]) }
        }
        return nil
    }
    private func contained(_ suffix: String, root: URL) -> URL? {
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return try? ReaderContainedPath.resolve(suffix, under: root)
    }
    func url(for path: String) -> URL? {
        guard let tail = suffix(path), let current = contained(tail, root: root) else { return nil }
        let legacy = contained(tail, root: legacyRoot)
        if path.hasPrefix("/"), let legacy, FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        if FileManager.default.fileExists(atPath: current.path) { return current }
        if let legacy, FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }
    func historyURL(for path: String) -> URL? {
        if suffix(path) != nil { return url(for: path) }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }
    func normalizedPath(_ path: String) -> String? {
        guard let tail = suffix(path), contained(tail, root: root) != nil else { return nil }
        if path.hasPrefix("/"), let legacy = contained(tail, root: legacyRoot), FileManager.default.fileExists(atPath: legacy.path) { return nil }
        return "Offline/" + tail
    }
    func relativePath(_ file: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { throw ReaderSafetyError.message("离线文件路径超出允许范围") }
        let tail = String(file.path.dropFirst(base.path.count + 1))
        guard contained(tail, root: root) != nil else { throw ReaderSafetyError.message("离线文件路径无效") }
        return "Offline/" + tail
    }
    func destination(id: UUID, attempt: UUID, isNAS: Bool, source: String, type: FileType) throws -> URL {
        let url = isNAS ? URL(fileURLWithPath: source) : URL(string: source)
        var name = url?.lastPathComponent ?? ""
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\0", with: "")
        let ext = (name as NSString).pathExtension
        let basename = (name as NSString).deletingPathExtension
        var short = ""
        for character in basename { if (short + String(character)).utf8.count > 160 { break }; short.append(character) }
        if short.isEmpty || short == "." || short == ".." { short = "文件" }
        name = short + (ext.isEmpty || ext.utf8.count > 16 ? "." + defaultExtension(type) : "." + ext)
        guard let file = contained("\(isNAS ? "nas" : "web")/\(id)/\(attempt)/\(name)", root: root) else { throw ReaderSafetyError.message("离线文件路径无效") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return file
    }
    private func defaultExtension(_ type: FileType) -> String {
        switch type { case .pdf: "pdf"; case .epub: "epub"; case .cbz: "cbz"; case .cbr: "cbr"; case .txt: "txt"; case .video: "mp4"; case .audio: "m4a"; case .image: "jpg"; default: "bin" }
    }
    func discardAttempt(file: URL) {
        guard (try? relativePath(file)) != nil else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
    func deleteFile(path: String) {
        guard let file = url(for: path), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
        try? FileManager.default.removeItem(at: file)
    }
    func clear() throws {
        for directory in [root, legacyRoot] where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    func migrateLegacyDirectory() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyRoot.path) else { return }
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ReaderSafetyError.message("离线目录不允许使用符号链接") }
        guard (try legacyRoot.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw ReaderSafetyError.message("离线目录不允许使用符号链接") }
        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: root.path) { try fm.moveItem(at: legacyRoot, to: root); return }
        func merge(_ source: URL, _ destination: URL) throws {
            for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { continue }
                let target = try ReaderContainedPath.resolve(file.lastPathComponent, under: destination)
                if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: file, to: target) }
                else if info.isDirectory == true, (try target.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { try merge(file, target) }
                // A conflicting legacy file remains readable; never overwrite either copy.
            }
            if try fm.contentsOfDirectory(atPath: source.path).isEmpty { try fm.removeItem(at: source) }
        }
        try merge(legacyRoot, root)
    }
    @MainActor func normalizeRecords(in context: ModelContext) async throws {
        let records = try context.fetch(FetchDescriptor<OfflineItem>())
        let snapshots = records.filter { $0.localPath.hasPrefix("/") }.map { ($0.id, $0.localPath) }
        guard !snapshots.isEmpty else { return }
        let paths = await Task.detached(priority: .utility) {
            snapshots.compactMap { id, path -> (UUID, String, String)? in
                guard let normalized = normalizedPath(path), normalized != path else { return nil }
                return (id, path, normalized)
            }
        }.value
        try Task.checkCancellation()
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [(OfflineItem, String)] = []
        for (id, previous, normalized) in paths {
            guard let item = byID[id], item.modelContext === context, item.localPath == previous else { continue }
            changed.append((item, previous)); item.localPath = normalized
        }
        if !changed.isEmpty {
            do { try context.save() }
            catch { for (item, previous) in changed { item.localPath = previous }; throw error }
        }
    }
}
