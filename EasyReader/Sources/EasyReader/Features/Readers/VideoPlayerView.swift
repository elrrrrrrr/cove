import SwiftUI
import AVKit
import SwiftData

struct VideoPlayerView: View {
    let fileURL: URL
    var historyItem: ReadingHistory?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var showBars = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                    }
            } else {
                ProgressView("加载中…").tint(.white)
            }

            if let player {
                VideoNetworkSpeedBadge(player: player)
                    .padding(.top, 58)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if showBars {
                VStack {
                    // Custom top bar
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .imageScale(.large)
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Text(fileURL.deletingPathExtension().lastPathComponent)
                            .foregroundStyle(.white)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        // AirPlay picker
                        RoutePickerView()
                            .frame(width: 44, height: 44)
                    }
                    .padding(.horizontal).padding(.top, 8)
                    .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .background(SwipeBackEnabler())
        .navigationBarHidden(true)
        .statusBarHidden(!showBars)
        .onAppear { setupPlayer() }
        .onDisappear { saveProgress() }
    }

    private func setupPlayer() {
        let item = AVPlayerItem(url: fileURL)
        let p = AVPlayer(playerItem: item)
        self.player = p
        p.play()
    }

    private func saveProgress() {
        guard let player else { return }
        let duration  = player.currentItem?.duration.seconds ?? 0
        let current   = player.currentTime().seconds
        let progress  = duration > 0 ? current / duration : 0
        player.pause()

        if let item = historyItem {
            item.progress   = progress
            item.lastReadAt = Date()
        } else {
            context.insert(ReadingHistory(
                title: fileURL.deletingPathExtension().lastPathComponent,
                filePath: fileURL.path,
                fileType: .video,
                progress: progress
            ))
        }
    }
}

// MARK: - AirPlay route picker wrapper

struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Video network speed badge

enum VideoNetworkSpeedEvent {
    static let smbStreamBytesRead = Notification.Name("EasyReader.VideoNetworkSpeedEvent.smbStreamBytesRead")
    static let pathKey = "path"
    static let bytesKey = "bytes"
}

struct VideoNetworkSpeedBadge: View {
    let player: AVPlayer?
    var streamKey: String?

    @State private var monitor = VideoNetworkSpeedMonitor()

    private var playerID: ObjectIdentifier? {
        player.map(ObjectIdentifier.init)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption2)
            Text(monitor.label)
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .allowsHitTesting(false)
        .onAppear {
            monitor.start(player: player, streamKey: streamKey)
        }
        .onChange(of: playerID) { _, _ in
            monitor.start(player: player, streamKey: streamKey)
        }
        .onChange(of: streamKey) { _, _ in
            monitor.start(player: player, streamKey: streamKey)
        }
        .onDisappear {
            monitor.stop()
        }
    }
}

@Observable
@MainActor
final class VideoNetworkSpeedMonitor {
    var label = "网速 --"

    private var sampleTask: Task<Void, Never>?
    private var smbObserver: NSObjectProtocol?
    private var streamBytes: Int64 = 0
    private var lastStreamBytes: Int64 = 0
    private var lastAccessBytes: Int64?
    private var lastTransferDuration: Double?

    func start(player: AVPlayer?, streamKey: String? = nil) {
        stop()

        guard let player else {
            label = "网速 --"
            return
        }

        label = isLocal(player: player) ? "本地" : "网速 --"

        if let streamKey {
            smbObserver = NotificationCenter.default.addObserver(
                forName: VideoNetworkSpeedEvent.smbStreamBytesRead,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let path = note.userInfo?[VideoNetworkSpeedEvent.pathKey] as? String,
                      path == streamKey,
                      let bytes = note.userInfo?[VideoNetworkSpeedEvent.bytesKey] as? Int else {
                    return
                }
                Task { @MainActor in
                    self?.streamBytes += Int64(bytes)
                }
            }
        }

        sampleTask = Task { [weak self, weak player] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.sample(player: player)
            }
        }
    }

    func stop() {
        sampleTask?.cancel()
        sampleTask = nil
        if let smbObserver {
            NotificationCenter.default.removeObserver(smbObserver)
        }
        smbObserver = nil
        streamBytes = 0
        lastStreamBytes = 0
        lastAccessBytes = nil
        lastTransferDuration = nil
    }

    private func sample(player: AVPlayer?) {
        guard let player else {
            label = "网速 --"
            return
        }

        let streamDelta = streamBytes - lastStreamBytes
        lastStreamBytes = streamBytes
        if streamDelta > 0 {
            label = Self.format(bytesPerSecond: Double(streamDelta))
            return
        }

        if let event = player.currentItem?.accessLog()?.events.last {
            let bytes = event.numberOfBytesTransferred
            let duration = event.transferDuration

            if let lastAccessBytes,
               let lastTransferDuration,
               bytes >= lastAccessBytes,
               duration > lastTransferDuration {
                let bytesPerSecond = Double(bytes - lastAccessBytes) / (duration - lastTransferDuration)
                if bytesPerSecond > 0 {
                    label = Self.format(bytesPerSecond: bytesPerSecond)
                    self.lastAccessBytes = bytes
                    self.lastTransferDuration = duration
                    return
                }
            }

            lastAccessBytes = bytes
            lastTransferDuration = duration

            if event.observedBitrate > 0 {
                label = Self.format(bytesPerSecond: event.observedBitrate / 8)
                return
            }
            if event.indicatedBitrate > 0 {
                label = Self.format(bytesPerSecond: event.indicatedBitrate / 8)
                return
            }
        }

        if isLocal(player: player) {
            label = "本地"
        } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            label = "缓冲中"
        } else {
            label = "网速 --"
        }
    }

    private func isLocal(player: AVPlayer) -> Bool {
        guard let asset = player.currentItem?.asset as? AVURLAsset else { return false }
        return asset.url.isFileURL
    }

    private static func format(bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024)
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
