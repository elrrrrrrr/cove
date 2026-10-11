import Foundation

struct FolderSyncProgress: Sendable, Equatable {
    var phase: String
    var fileName: String?
    var fileNumber: Int = 0
    var fileCount: Int = 0
    var completedBytes: Int64?
    var totalBytes: Int64?

    var fraction: Double? {
        guard let completedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
    var byteDescription: String? {
        guard let completedBytes, let totalBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: completedBytes)) / \(formatter.string(fromByteCount: totalBytes))"
    }
}
