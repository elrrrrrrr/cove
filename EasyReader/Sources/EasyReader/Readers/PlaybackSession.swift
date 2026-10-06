import AVFoundation
import Observation

@Observable @MainActor final class PlaybackSession {
    var player: AVPlayer?
    var loading = false
    var error: String?
    var ended = false
    var playhead: Double = 0
    var duration: Double = 0
    var isPlaying = false
    @ObservationIgnored var onEnded: (() -> Void)?
    private var providerLease: (any SourceProvider)?
    private var entry: LibraryEntry?
    private var library: LibraryStore?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var generation = 0

    func open(item: ResourceItem, asset: MediaAsset, provider: (any SourceProvider)?,
              library: LibraryStore, autoplay: Bool) async {
        stop()
        generation += 1
        let token = generation
        loading = true; error = nil; ended = false
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let playerItem: AVPlayerItem
            if let path = asset.smbPath, let smb = provider as? SMBSourceProvider {
                playerItem = try SMBStreamLoader.playerItem(client: smb.client, path: path)
            } else if let url = asset.url {
                playerItem = AVPlayerItem(asset: AVURLAsset(url: url, options: asset.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": asset.headers]))
            } else { throw CoveError.message("播放资源无效") }
            try Task.checkCancellation()
            guard token == generation else { return }
            let entry = try library.opened(item)
            self.entry = entry; self.library = library; self.providerLease = provider
            let player = AVPlayer(playerItem: playerItem)
            self.player = player
            statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let failed = item.status == .failed
                let message = item.error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if failed { self.error = message ?? "播放器不支持此媒体格式"; self.loading = false }
                }
            }
            if entry.position > 0 { await player.seek(to: CMTime(seconds: entry.position, preferredTimescale: 600)) }
            try Task.checkCancellation()
            guard token == generation else { player.pause(); return }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.generation == token { self?.record() } }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.ended = true; self.record(); self.onEnded?()
                }
            }
            loading = false
            if autoplay { player.play() }
        } catch is CancellationError { if token == generation { loading = false } }
        catch { if token == generation { self.error = error.localizedDescription; loading = false } }
    }
    private func record() {
        guard let player, let entry else { return }
        let position = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        if position.isFinite && position >= 0 {
            playhead = position; self.duration = duration.isFinite && duration > 0 ? duration : 0; isPlaying = player.rate > 0
            entry.position = position
            if duration.isFinite && duration > 0 { entry.progress = min(1, position / duration) }
        }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        playhead = seconds
    }
    func stop() {
        generation += 1
        player?.pause(); record()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let library { do { try library.persist() } catch { library.error = error.localizedDescription } }
        player = nil; entry = nil; providerLease = nil; loading = false; ended = false
    }
}
