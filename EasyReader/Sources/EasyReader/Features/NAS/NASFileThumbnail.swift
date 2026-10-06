import SwiftUI

/// Shows a thumbnail for NAS image/video files, or a system icon for other types.
/// Supports SMB, DSM, and fnOS connections.
struct NASFileThumbnail: View {
    let entry: NASFileEntry
    let connection: NASConnection?
    var size: CGFloat = 80
    var loadsThumbnail = true

    @State private var thumbnail: UIImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadToken: UUID?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(entry.isDirectory ? .systemYellow.withAlphaComponent(0.1) : UIColor.secondarySystemBackground)
                    .overlay {
                        Image(systemName: entry.isDirectory ? "folder.fill" : entry.fileType.systemImage)
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(entry.isDirectory ? .yellow : Color.accentColor)
                    }
            }
        }
        .onAppear {
            scheduleThumbnailLoad()
        }
        .onDisappear {
            cancelThumbnailLoad()
        }
        .onChange(of: entry.path) {
            thumbnail = nil
            cancelThumbnailLoad()
            scheduleThumbnailLoad()
        }
    }

    @MainActor
    private func scheduleThumbnailLoad() {
        guard loadsThumbnail, thumbnail == nil, loadTask == nil, let connection else { return }

        let fileType = entry.fileType
        guard fileType == .image || fileType == .video else { return }

        let path = entry.path
        let fileSize = entry.size
        let token = UUID()
        loadToken = token

        loadTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                await clearLoadTask(token: token)
                return
            }

            let image: UIImage?
            switch fileType {
            case .image:
                image = await NASThumbnailCache.shared.thumbnail(
                    for: path, fileSize: fileSize, connection: connection
                )
            case .video:
                image = await NASThumbnailCache.shared.videoThumbnail(
                    for: path, connection: connection
                )
            default:
                image = nil
            }

            guard !Task.isCancelled else {
                await clearLoadTask(token: token)
                return
            }

            await MainActor.run {
                guard loadToken == token else { return }
                thumbnail = image
                loadTask = nil
                loadToken = nil
            }
        }
    }

    @MainActor
    private func cancelThumbnailLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadToken = nil
        let path = entry.path
        Task {
            await NASThumbnailCache.shared.cancel(path: path)
        }
    }

    @MainActor
    private func clearLoadTask(token: UUID) {
        guard loadToken == token else { return }
        loadTask = nil
        loadToken = nil
    }
}
