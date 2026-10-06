import Foundation
import Observation

@Observable @MainActor final class OfflineService {
    struct Job: Identifiable {
        var id: String { item.id }
        let item: ResourceItem
        let token: UUID
        var status: String
        var progress: Double
    }
    private(set) var jobs: [Job] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private let slots = AsyncSlots(limit: 2)

    func start(_ item: ResourceItem, sources: SourceStore, library: LibraryStore) {
        cancel(item.id)
        let token = UUID()
        jobs.append(Job(item: item, token: token, status: "等待下载", progress: 0))
        tasks[item.id] = Task { [weak self] in
            guard let self, await slots.acquire() else { return }
            do {
                update(item.id, token: token, status: "正在下载")
                let provider = try sources.provider(id: item.sourceID)
                let transferred = try await OfflineTransfer.file(item, provider: provider)
                defer { try? FileManager.default.removeItem(at: transferred.file) }
                try Task.checkCancellation()
                guard jobs.contains(where: { $0.id == item.id && $0.token == token }) else { await slots.release(); return }
                let relative = "offline/" + item.id + "-" + token.uuidString.lowercased() + "." + transferred.format
                let destination = try ContainedPath.resolve(relative, under: CoveStorage.data)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: transferred.file, to: destination)
                do {
                    let entry = try library.entry(for: item)
                    let previous = entry.offlineRelativePath
                    entry.offlineRelativePath = relative
                    try library.persist()
                    if let previous, let old = try? ContainedPath.resolve(previous, under: CoveStorage.data) { try? FileManager.default.removeItem(at: old) }
                } catch { try? FileManager.default.removeItem(at: destination); throw error }
                update(item.id, token: token, status: "已保存", progress: 1)
            } catch is CancellationError { }
            catch { update(item.id, token: token, status: error.localizedDescription) }
            await slots.release()
            if jobs.contains(where: { $0.id == item.id && $0.token == token }) { tasks.removeValue(forKey: item.id) }
        }
    }
    private func update(_ id: String, token: UUID, status: String, progress: Double = 0) {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.token == token }) else { return }
        jobs[index].status = status; jobs[index].progress = progress
    }
    func cancel(_ id: String) { tasks.removeValue(forKey: id)?.cancel(); jobs.removeAll { $0.id == id } }
}

private enum OfflineTransfer {
    struct File: Sendable { let file: URL; let format: String }
    @MainActor static func file(_ item: ResourceItem, provider: any SourceProvider) async throws -> File {
        guard item.kind != .folder, (item.byteSize ?? 0) <= 2 * 1024 * 1024 * 1024 else { throw CoveError.message("离线保存仅支持不超过 2 GB 的单个文件") }
        let format = item.fileExtension.isEmpty ? (item.kind == .video ? "mp4" : "data") : item.fileExtension
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cove-offline-" + UUID().uuidString)
        do {
            if let smb = provider as? SMBSourceProvider {
                guard try await smb.client.size(path: item.locator) <= 2 * 1024 * 1024 * 1024 else { throw CoveError.message("离线文件超过 2 GB") }
                try await smb.client.download(path: item.locator, to: temporary)
                return File(file: temporary, format: format)
            }
            let resolved = try await provider.resolve(item)
            switch resolved {
            case .document(let url), .image(let url): return try await copyOrDownload(url, format: url.pathExtension, headers: [:], temporary: temporary)
            case .comic(let content):
                guard let file = content.localArchive else { throw CoveError.message("网页漫画暂不支持整本离线保存") }
                return try await copyOrDownload(file, format: file.pathExtension, headers: [:], temporary: temporary)
            case .media(let media):
                guard let url = media.url, media.format != "hls", url.pathExtension.lowercased() != "m3u8" else { throw CoveError.message("HLS 暂不支持离线保存，可在线播放") }
                return try await copyOrDownload(url, format: url.pathExtension.isEmpty ? format : url.pathExtension, headers: media.headers, temporary: temporary)
            default: throw CoveError.message("此内容没有可下载的文件")
            }
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    private static func copyOrDownload(_ url: URL, format: String, headers: [String: String], temporary: URL) async throws -> File {
        if url.isFileURL {
            try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: url, to: temporary) }.value
        } else {
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let file = try await BoundedDownloader.download(request, maxBytes: 2 * 1024 * 1024 * 1024)
            defer { try? FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: file, to: temporary)
        }
        let safe = format.range(of: #"^[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil ? format : "data"
        return File(file: temporary, format: safe)
    }
}
