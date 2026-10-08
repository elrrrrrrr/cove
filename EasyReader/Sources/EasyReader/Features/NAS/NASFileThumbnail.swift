import SwiftUI

/// Shows a thumbnail for NAS image/video files, or a system icon for other types.
/// Uses cancellable, shared SMB thumbnail requests.
struct NASFileThumbnail: View {
    let entry: NASFileEntry
    let connection: NASConnection?
    var size: CGFloat = 80
    var loadsThumbnail = true

    @Environment(\.displayScale) private var scale
    @State private var pixels = 256
    private var revision: String { NASThumbnailCache.key(connectionID: connection?.cacheIdentity ?? "", entry: entry, pixels: pixels) }
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
        .onGeometryChange(for: Int.self) { [scale] proxy in
            ImageSizing.pixels(points: max(proxy.size.width, proxy.size.height), scale: scale)
        } action: { pixels = $0 }
        .onAppear {
            scheduleThumbnailLoad()
        }
        .onDisappear {
            cancelThumbnailLoad()
        }
        .onChange(of: revision) {
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

        let entry = entry
        let pixels = pixels
        let token = UUID()
        loadToken = token

        loadTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                clearLoadTask(token: token)
                return
            }

            let image = await NASThumbnailCache.shared.thumbnail(for: entry, connection: connection, pixels: pixels)

            guard !Task.isCancelled else {
                clearLoadTask(token: token)
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

    }

    @MainActor
    private func clearLoadTask(token: UUID) {
        guard loadToken == token else { return }
        loadTask = nil
        loadToken = nil
    }
}
