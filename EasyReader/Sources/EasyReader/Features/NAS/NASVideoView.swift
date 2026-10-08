import SwiftUI
import AVKit
import AVFoundation

/// Video player for NAS files — vertical swipe to navigate (like short-video apps).
/// Supports SMB streaming and local/HTTP media URLs.
struct NASVideoView: View {
    // Source: local file URL (from download) or streaming player item
    var fileURL: URL?
    var streamItem: AVPlayerItem?
    var streamURL: URL?  // Direct HTTP media URL

    // Sibling navigation
    var files: [NASFileEntry] = []
    var initialIndex: Int = 0
    var client: SMBClient?

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0

    init(
        fileURL: URL? = nil,
        streamItem: AVPlayerItem? = nil,
        streamURL: URL? = nil,
        files: [NASFileEntry] = [],
        initialIndex: Int = 0,
        client: SMBClient? = nil
    ) {
        self.fileURL = fileURL
        self.streamItem = streamItem
        self.streamURL = streamURL
        self.files = files
        self.initialIndex = initialIndex
        self.client = client
        _currentIndex = State(initialValue: Self.normalizedIndex(initialIndex, count: files.count))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if files.count > 1 {
                // Vertical paging for multiple videos
                TabView(selection: $currentIndex) {
                    ForEach(Array(files.enumerated()), id: \.offset) { idx, entry in
                        VideoPage(
                            entry: entry,
                            client: client,

                            isInitial: idx == initialIndex,
                            initialFileURL: idx == initialIndex ? fileURL : nil,
                            initialStreamItem: idx == initialIndex ? streamItem : nil,
                            initialStreamURL: idx == initialIndex ? streamURL : nil,
                            isActive: idx == currentIndex
                        )
                        .ignoresSafeArea()
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .ignoresSafeArea()
            } else {
                // Single video — no paging
                VideoPage(
                    entry: files.first,
                    client: client,

                    isInitial: true,
                    initialFileURL: fileURL,
                    initialStreamItem: streamItem,
                    initialStreamURL: streamURL,
                    isActive: true
                )
                .ignoresSafeArea()
            }

            // Overlay controls
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    if files.count > 1 {
                        Text("\(currentIndex + 1) / \(files.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                }
                .padding(.top, 54)
                .padding(.horizontal, 16)

                Spacer()

                // Filename
                if currentIndex < files.count {
                    Text(files[currentIndex].name)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 40)
                }
            }
        }
        .navigationBarHidden(true)
        .background(SwipeBackEnabler())
    }

    private static func normalizedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}

// MARK: - Single video page

/// One page in the vertical pager — manages its own player lifecycle.
private struct VideoPage: View {
    let entry: NASFileEntry?
    let client: SMBClient?
    let isInitial: Bool
    let initialFileURL: URL?
    let initialStreamItem: AVPlayerItem?
    let initialStreamURL: URL?
    let isActive: Bool

    @State private var player: AVPlayer?
    @State private var isLoadingFile = false
    @State private var loadTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var temporaryURL: URL?

    var body: some View {
        ZStack {
            Color.black

            if player != nil {
                NASPlayerViewController(player: $player)
            } else if let loadError {
                Text(loadError).foregroundStyle(.white).padding()
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let player {
                VideoNetworkSpeedBadge(player: player, streamKey: entry?.path)
                    .padding(.top, 96)
                    .padding(.trailing, 16)
            }
        }
        .onAppear {
            if isActive { startIfNeeded() }
        }
        .onChange(of: isActive) { _, active in
            if active {
                startIfNeeded()
            } else {
                teardownPlayer()
            }
        }
        .onDisappear {
            teardownPlayer()
        }
    }

    private func startIfNeeded() {
        guard loadTask == nil else { return }
        if let player {
            player.play()
            return
        }

        if isInitial, let item = initialStreamItem {
            setupPlayer(item: item)
        } else if isInitial, let url = initialStreamURL {
            setupPlayer(url: url)
        } else if isInitial, let url = initialFileURL {
            setupPlayer(url: url)
        } else if let entry {
            loadEntry(entry)
        }
    }

    private func loadEntry(_ entry: NASFileEntry) {
        // SMB: stream or download
        guard let client else { return }
        if SMBStreamLoader.supportsVideo(path: entry.path) {
            let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path)
            setupPlayer(item: item)
        } else {
            downloadAndPlay(entry: entry, client: client)
        }
    }

    private func setupPlayer(item: AVPlayerItem) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.pause()
        SMBStreamLoader.cancel(in: player?.currentItem?.asset)
        player?.replaceCurrentItem(with: nil)
        let p = AVPlayer(playerItem: item)
        player = p
        p.play()
    }

    private func setupPlayer(url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.pause()
        SMBStreamLoader.cancel(in: player?.currentItem?.asset)
        player?.replaceCurrentItem(with: nil)
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }

    private func downloadAndPlay(entry: NASFileEntry, client: SMBClient) {
        guard !isLoadingFile else { return }
        isLoadingFile = true
        loadError = nil
        loadTask = Task {
            do {
                let dest = try await client.temporaryFile(for: entry.path)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
                    return
                }
                await MainActor.run {
                    temporaryURL = dest
                    isLoadingFile = false
                    loadTask = nil
                    setupPlayer(url: dest)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isLoadingFile = false
                    loadTask = nil
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func teardownPlayer() {
        loadTask?.cancel()
        loadTask = nil
        isLoadingFile = false
        player?.pause()
        SMBStreamLoader.cancel(in: player?.currentItem?.asset)
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent()) }
        temporaryURL = nil
    }
}

// MARK: - Video player (AVPlayerViewController wrapper)

private struct NASPlayerViewController: UIViewControllerRepresentable {
    @Binding var player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
        vc.player = nil
    }
}
