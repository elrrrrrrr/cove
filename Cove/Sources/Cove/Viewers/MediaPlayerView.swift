import SwiftUI
import AVKit
import AVFoundation
import SwiftData

struct MediaPlayerView: View {
    enum Source {
        case web(item: ParsedItem, definitionID: String?)
        case localVideo(url: URL, history: ReadingHistory?)
        case nasVideo(entries: [NASFileEntry], initialIndex: Int, clientID: String)
        case localAudio(url: URL, title: String)
        case nasAudio(entries: [NASFileEntry], initialIndex: Int, clientID: String)
    }

    let source: Source

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var session = WebSession()
    @State private var player: AVPlayer?
    @State private var webResult: VideoResult?
    @State private var webFailed = false
    @State private var isPlaying = false
    @State private var showInspect = false
    @State private var activeTitle = ""
    @State private var activePageURL: URL?
    @State private var nasIndex = 0
    @State private var tempFile: URL?
    @State private var loadTask: Task<Void, Never>?
    @State private var audioTime: Double = 0
    @State private var audioDuration: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            contentBody
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await start() }
        .onDisappear { cleanup() }
        .sheet(isPresented: $showInspect) {
            if let req = session.originalRequest ?? activePageURL.map({ URLRequest(url: $0) }) {
                ParsingWebViewSheet(webView: session.webView, request: req)
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch source {
        case .web(let item, _):
            if webResult != nil, player != nil {
                ZStack(alignment: .topLeading) {
                    AVPlayerSurface(player: $player) { advanceEpisode() }
                        .ignoresSafeArea()
                    floatingCloseButton
                }
            } else if webFailed, let url = activePageURL ?? Optional(item.pageURL) {
                ZStack(alignment: .topLeading) {
                    WebBrowserView(url: url)
                        .overlay(alignment: .topTrailing) {
                            Button("重试解析", systemImage: "arrow.clockwise") {
                                webFailed = false
                                Task { await loadWebVideo(url: url, title: item.title, thumbnail: item.thumbnail, defID: defID) }
                            }
                            .buttonStyle(.borderedProminent)
                            .padding()
                        }
                    floatingCloseButton
                }
            } else {
                ambientLoadingView(item: item)
            }

        case .localVideo:
            if player != nil {
                ZStack(alignment: .topLeading) {
                    AVPlayerSurface(player: $player, onEnded: nil)
                        .ignoresSafeArea()
                    floatingCloseButton
                }
            } else {
                ProgressView().tint(.white)
            }

        case .nasVideo(let entries, _, _):
            ZStack {
                if player != nil {
                    AVPlayerSurface(player: $player, onEnded: nil).ignoresSafeArea()
                } else {
                    ProgressView("加载视频…").tint(.white)
                }
                VStack {
                    HStack {
                        floatingCloseButton
                        Spacer()
                        if entries.count > 1 {
                            HStack(spacing: 12) {
                                Button { switchNASVideo(offset: -1) } label: { Image(systemName: "chevron.left") }
                                    .disabled(nasIndex <= 0)
                                Text("\(nasIndex + 1)/\(entries.count)").font(.caption.monospacedDigit())
                                Button { switchNASVideo(offset: 1) } label: { Image(systemName: "chevron.right") }
                                    .disabled(nasIndex >= entries.count - 1)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glassEffect(.regular, in: Capsule())
                        }
                    }
                    .padding()
                    Spacer()
                }
            }

        case .localAudio, .nasAudio:
            audioPlayerBody
        }
    }

    private var defID: String? {
        if case .web(_, let d) = source { return d }
        return nil
    }

    private var floatingCloseButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: Circle())
        }
        .accessibilityIdentifier("player.close")
        .padding(.leading, 16).padding(.top, 12)
    }

    private func ambientLoadingView(item: ParsedItem) -> some View {
        GeometryReader { geo in
            ZStack {
                CoveImage(url: item.thumbnail, referer: item.pageURL, definitionID: defID)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped().blur(radius: 28).overlay(.black.opacity(0.62))
                VStack(spacing: 22) {
                    if item.thumbnail != nil {
                        CoveImage(url: item.thumbnail, referer: item.pageURL, definitionID: defID, contentMode: .fit)
                            .frame(maxWidth: 300, maxHeight: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("解析视频地址中…").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                    ItemTitleView(title: item.title, titleImage: item.titleImage, referer: item.pageURL,
                                  definitionID: defID, font: .headline, fontSize: 17,
                                  foregroundColor: .white, alignment: .center)
                        .padding(.horizontal, 28)
                    HStack(spacing: 14) {
                        Button("查看原始网页", systemImage: "safari") { showInspect = true }
                        Button("返回") { dismiss() }
                    }
                    .buttonStyle(.bordered).tint(.white)
                }
            }
        }
    }

    private var audioPlayerBody: some View {
        VStack(spacing: 28) {
            HStack {
                floatingCloseButton
                Spacer()
            }
            Spacer()
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 220, height: 220)
                .overlay { Image(systemName: "waveform").font(.system(size: 64)).foregroundStyle(.white.opacity(0.85)) }
            Text(activeTitle).font(.title3.weight(.semibold)).foregroundStyle(.white).lineLimit(2).padding(.horizontal)
            VStack(spacing: 8) {
                Slider(value: Binding(
                    get: { audioTime },
                    set: { player?.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }
                ), in: 0...max(audioDuration, 1))
                HStack {
                    Text(formatTime(audioTime)); Spacer(); Text(formatTime(audioDuration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }.padding(.horizontal, 32)
            HStack(spacing: 36) {
                if case .nasAudio(let entries, _, _) = source {
                    Button { switchNASAudio(offset: -1) } label: { Image(systemName: "backward.fill").font(.title2) }
                        .disabled(nasIndex <= 0)
                    Button { toggleAudioPlay() } label: { Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 60)) }
                    Button { switchNASAudio(offset: 1) } label: { Image(systemName: "forward.fill").font(.title2) }
                        .disabled(nasIndex >= entries.count - 1)
                } else {
                    Button { toggleAudioPlay() } label: { Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 60)) }
                }
            }.foregroundStyle(.white)
            Spacer()
        }
    }

    // MARK: - Playback Control

    private func start() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        switch source {
        case .web(let item, let d):
            activeTitle = item.title; activePageURL = item.pageURL
            await loadWebVideo(url: item.pageURL, title: item.title, thumbnail: item.thumbnail, defID: d)
        case .localVideo(let url, let history):
            activeTitle = url.deletingPathExtension().lastPathComponent
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            player = p
            if let f = history?.clampedFraction, f > 0, f < 0.99,
               let dur = try? await item.asset.load(.duration), dur.seconds.isFinite, dur.seconds > 0 {
                await p.seek(to: CMTime(seconds: dur.seconds * f, preferredTimescale: 600))
            }
            p.play()
        case .nasVideo(_, let initialIndex, _):
            nasIndex = initialIndex
            await playNASVideo(at: initialIndex)
        case .localAudio(let url, let title):
            activeTitle = title
            startAudio(item: AVPlayerItem(url: url))
        case .nasAudio(_, let initialIndex, _):
            nasIndex = initialIndex
            await playNASAudio(at: initialIndex)
        }
    }

    private func loadWebVideo(url: URL, title: String, thumbnail: URL?, defID: String?) async {
        activePageURL = url
        if let result = await session.extractVideo(url: url, definitionID: defID) {
            webResult = result
            let saved = ReadingHistory.find(in: context, url: url.absoluteString, fileType: .video)?.progress ?? 0
            let asset = result.headers.isEmpty ? AVURLAsset(url: result.streamURL)
                : AVURLAsset(url: result.streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": result.headers])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            if saved > 2 { await p.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
            player = p; p.play()
            let finalTitle = result.episodeNumber.map { "\(result.title ?? title) · 第\($0)集" } ?? title
            ReadingHistory.recordProgress(
                in: context, title: finalTitle, url: url.absoluteString, fileType: .video,
                progress: saved, thumbnailURLString: thumbnail?.absoluteString, definitionID: defID, updateTitle: true
            )
        } else {
            webFailed = true
        }
    }

    private func advanceEpisode() {
        guard case .web(let item, let d) = source, let nextURL = webResult?.nextPageURL else { return }
        saveCurrentProgress(); player?.pause(); player = nil; webResult = nil
        Task { await loadWebVideo(url: nextURL, title: item.title, thumbnail: item.thumbnail, defID: d) }
    }

    private func switchNASVideo(offset: Int) {
        let next = nasIndex + offset
        guard case .nasVideo(let entries, _, _) = source, entries.indices.contains(next) else { return }
        nasIndex = next
        loadTask?.cancel(); loadTask = Task { await playNASVideo(at: next) }
    }

    private func playNASVideo(at index: Int) async {
        guard case .nasVideo(let entries, _, let clientID) = source, entries.indices.contains(index),
              let client = await SMBClientRegistry.shared.client(for: clientID) else { return }
        teardownNASPlayer()
        let entry = entries[index]
        activeTitle = entry.name
        if SMBStreamLoader.supportsVideo(path: entry.path) {
            let p = AVPlayer(playerItem: SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path))
            player = p; p.play()
        } else if let url = try? await client.temporaryFile(for: entry.path) {
            tempFile = url
            let p = AVPlayer(playerItem: AVPlayerItem(url: url))
            player = p; p.play()
        }
    }

    private func switchNASAudio(offset: Int) {
        let next = nasIndex + offset
        guard case .nasAudio(let entries, _, _) = source, entries.indices.contains(next) else { return }
        nasIndex = next
        loadTask?.cancel(); loadTask = Task { await playNASAudio(at: next) }
    }

    private func playNASAudio(at index: Int) async {
        guard case .nasAudio(let entries, _, let clientID) = source, entries.indices.contains(index),
              let client = await SMBClientRegistry.shared.client(for: clientID) else { return }
        let entry = entries[index]
        activeTitle = (entry.name as NSString).deletingPathExtension
        startAudio(item: SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path))
    }

    private func startAudio(item: AVPlayerItem) {
        teardownAudioObserver()
        let p = AVPlayer(playerItem: item)
        player = p; isPlaying = true; p.play()
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak p] t in
            Task { @MainActor in
                audioTime = t.seconds.isFinite ? t.seconds : 0
                let d = p?.currentItem?.duration.seconds ?? 0
                audioDuration = d.isFinite ? d : 0
            }
        }
    }

    private func toggleAudioPlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    private func saveCurrentProgress() {
        guard let p = player else { return }
        let secs = p.currentTime().seconds
        guard secs.isFinite, secs > 1 else { return }
        switch source {
        case .web(let item, let d):
            guard let url = activePageURL else { return }
            ReadingHistory.recordProgress(in: context, title: item.title, url: url.absoluteString, fileType: .video, progress: secs, definitionID: d)
        case .localVideo(let url, let history):
            let dur = p.currentItem?.duration.seconds ?? 0
            guard dur.isFinite, dur > 0 else { return }
            ReadingHistory.recordProgress(in: context, historyItem: history, title: url.deletingPathExtension().lastPathComponent,
                                          filePath: url.path, fileType: .video, progress: min(max(secs / dur, 0), 1))
        default: break
        }
    }

    private func teardownNASPlayer() {
        player?.pause()
        SMBStreamLoader.cancel(in: player?.currentItem?.asset)
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let file = tempFile { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); tempFile = nil }
    }

    private func teardownAudioObserver() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func cleanup() {
        loadTask?.cancel(); session.cancel()
        saveCurrentProgress(); teardownAudioObserver(); teardownNASPlayer()
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - AVPlayerViewController Wrapper

private struct AVPlayerSurface: UIViewControllerRepresentable {
    @Binding var player: AVPlayer?
    let onEnded: (@MainActor () -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onEnded: onEnded) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = true
        context.coordinator.sync(player: player)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        context.coordinator.onEnded = onEnded
        context.coordinator.sync(player: player)
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        vc.player?.pause(); vc.player = nil; coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onEnded: (@MainActor () -> Void)?
        private weak var item: AVPlayerItem?
        init(onEnded: (@MainActor () -> Void)?) { self.onEnded = onEnded }

        func sync(player: AVPlayer?) {
            let current = onEnded != nil ? player?.currentItem : nil
            guard current !== item else { return }
            stop()
            item = current
            if let current {
                NotificationCenter.default.addObserver(self, selector: #selector(ended), name: AVPlayerItem.didPlayToEndTimeNotification, object: current)
            }
        }
        func stop() { NotificationCenter.default.removeObserver(self); item = nil }
        @objc private func ended() { onEnded?() }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
