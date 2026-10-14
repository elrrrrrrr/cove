import Foundation
import SwiftData

/// Represents an article/file that has been saved for offline reading.
@Model
final class OfflineItem {
    var id: UUID
    var title: String
    var sourceURL: String?        // original web URL (nil for NAS files)
    var localPath: String         // relative to Application Support/Cove/data
    var fileType: FileType
    var savedAt: Date
    var fileSizeBytes: Int64
    var thumbnailData: Data?

    init(
        title: String,
        sourceURL: String? = nil,
        localPath: String,
        fileType: FileType,
        fileSizeBytes: Int64 = 0
    ) {
        self.id = UUID()
        self.title = title
        self.sourceURL = sourceURL
        self.localPath = localPath
        self.fileType = fileType
        self.savedAt = Date()
        self.fileSizeBytes = fileSizeBytes
    }

    /// Human-readable file size string.
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}
