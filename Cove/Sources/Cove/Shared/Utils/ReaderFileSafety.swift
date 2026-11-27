import Foundation
import ZIPFoundation

enum ReaderSafetyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ReaderContainedPath {
    static func resolve(_ relative: String, under root: URL, relativeTo base: URL? = nil) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("\\"),
              !relative.contains("\0"), !relative.contains("\\") else {
            throw ReaderSafetyError.message("资源路径不允许使用绝对地址")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var destination = (base ?? root).standardizedFileURL.resolvingSymlinksInPath()
        func contained(_ url: URL) -> Bool {
            url.path == canonicalRoot.path || url.path.hasPrefix(canonicalRoot.path == "/" ? "/" : canonicalRoot.path + "/")
        }
        guard contained(destination) else { throw ReaderSafetyError.message("资源目录超出了允许范围") }
        // Resolving an entire nonexistent leaf does not reliably resolve an existing
        // symlink parent on every OS. Walk components and reject links before proceeding.
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { destination.deleteLastPathComponent() }
            else {
                destination.appendPathComponent(String(component))
                if (try? FileManager.default.attributesOfItem(atPath: destination.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                    throw ReaderSafetyError.message("资源路径不允许通过符号链接")
                }
            }
            guard contained(destination) else { throw ReaderSafetyError.message("资源路径超出了允许的目录") }
        }
        guard destination.path != canonicalRoot.path else {
            throw ReaderSafetyError.message("资源路径不能指向根目录")
        }
        return destination
    }
}

enum ReaderArchive {
    static func extract(
        archiveURL: URL,
        to destination: URL,
        maxEntryBytes: UInt64 = 128 * 1024 * 1024,
        maxTotalBytes: UInt64 = 1024 * 1024 * 1024,
        filter: (Entry) -> Bool = { _ in true }
    ) throws -> [URL] {
        let fm = FileManager.default
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: nil)
        } catch {
            throw ReaderSafetyError.message("无效的压缩包文件")
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("." + UUID().uuidString + ".extract", isDirectory: true)
        var relatives: [String] = []
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var expanded: UInt64 = 0
            for entry in archive where !entry.path.hasPrefix("__MACOSX") && filter(entry) {
                try Task.checkCancellation()
                if entry.type == .directory { continue }
                guard entry.type != .symlink, entry.uncompressedSize <= maxEntryBytes,
                      expanded <= maxTotalBytes - entry.uncompressedSize else {
                    throw ReaderSafetyError.message("压缩包超过安全解包限制")
                }
                let target = try ReaderContainedPath.resolve(entry.path, under: staging)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                guard fm.createFile(atPath: target.path, contents: nil) else {
                    throw ReaderSafetyError.message("无法创建解包文件")
                }
                let handle = try FileHandle(forWritingTo: target)
                var entryBytes: UInt64 = 0
                do {
                    _ = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                        try Task.checkCancellation()
                        let count = UInt64(chunk.count)
                        guard entryBytes <= maxEntryBytes - count,
                              expanded <= maxTotalBytes - count else {
                            throw ReaderSafetyError.message("压缩包超过安全解包限制")
                        }
                        entryBytes += count
                        expanded += count
                        try handle.write(contentsOf: chunk)
                    }
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                let stagingPath = staging.standardizedFileURL.resolvingSymlinksInPath().path
                let rel = String(target.path.dropFirst(stagingPath.count + 1))
                relatives.append(rel)
            }
            try Task.checkCancellation()
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            return relatives.compactMap { try? ReaderContainedPath.resolve($0, under: destination) }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
