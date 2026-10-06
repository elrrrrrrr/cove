import Foundation
import ZIPFoundation

protocol ArchiveDecoder: Sendable {
    func supports(extension fileExtension: String) -> Bool
    func extract(file: URL, into root: URL) throws
}

struct ZIPArchiveDecoder: ArchiveDecoder {
    func supports(extension fileExtension: String) -> Bool { ["zip", "cbz", "epub"].contains(fileExtension) }
    func extract(file: URL, into root: URL) throws {
        let archive = try Archive(url: file, accessMode: .read, pathEncoding: nil)
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= 20_000, entry.type != .symlink,
                  entry.uncompressedSize <= 128 * 1024 * 1024,
                  total <= 1024 * 1024 * 1024 - entry.uncompressedSize else {
                throw CoveError.message("压缩包包含不允许的链接或超过解包限制")
            }
            total += entry.uncompressedSize
            let destination = try ContainedPath.resolve(entry.path, under: root)
            _ = try archive.extract(entry, to: destination, bufferSize: 64 * 1024)
        }
    }
}

final class ArchiveDocument: @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }
    deinit {
        let root = root
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: root) }
    }
}

enum ArchiveService {
    static let decoders: [any ArchiveDecoder] = [ZIPArchiveDecoder()]
    static func open(_ file: URL) throws -> ArchiveDocument {
        let ext = file.pathExtension.lowercased()
        guard let decoder = decoders.first(where: { $0.supports(extension: ext) }) else {
            throw CoveError.message(["rar", "cbr"].contains(ext)
                ? "此版本尚未包含 RAR 解码器，请先转换为 CBZ"
                : "暂不支持此压缩格式")
        }
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes <= 512 * 1024 * 1024 else { throw CoveError.message("压缩文件超过 512 MB") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoveArchives", isDirectory: true)
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try decoder.extract(file: file, into: root); return ArchiveDocument(root: root) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func comicPages(_ document: ArchiveDocument) throws -> [URL] {
        let names = try FileManager.default.subpathsOfDirectory(atPath: document.root.path)
        return try names.filter {
            !$0.hasPrefix("__MACOSX/") && ResourceKind.detect(path: $0) == .image
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { try ContainedPath.resolve($0, under: document.root) }
    }
    static func cleanAbandoned(now: Date = .now) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveArchives")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if now.timeIntervalSince(date) > 6 * 3600 { try? FileManager.default.removeItem(at: url) }
        }
    }
}
