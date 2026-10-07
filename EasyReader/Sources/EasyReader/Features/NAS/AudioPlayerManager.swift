import AVFoundation
import Observation

/// Singleton audio player that persists across view dismissals for background playback.
@Observable
@MainActor
final class AudioPlayerManager {
    static let shared = AudioPlayerManager()

    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var trackName: String = ""
    private(set) var trackPath: String = ""

    // Sibling navigation context
    private(set) var siblings: [NASFileEntry] = []
    private(set) var currentIndex: Int = 0
    private var smbClient: SMBClient?

    private var timeObserver: Any?

    private init() {}

    // MARK: - Playback

    /// Play from a streaming AVPlayerItem (SMB) or a local/HTTP URL.
    func play(item: AVPlayerItem? = nil, url: URL? = nil,
              name: String, path: String,
              siblings: [NASFileEntry] = [], currentIndex: Int = 0,
              client: SMBClient? = nil) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        cleanup()

        let p: AVPlayer
        if let item {
            p = AVPlayer(playerItem: item)
        } else if let url {
            p = AVPlayer(url: url)
        } else {
            return
        }

        player = p
        trackName = name
        trackPath = path
        self.siblings = siblings
        self.currentIndex = currentIndex
        self.smbClient = client

        // Duration
        Task {
            if let d = try? await p.currentItem?.asset.load(.duration) {
                let secs = d.seconds
                if secs.isFinite { await MainActor.run { duration = secs } }
            }
        }

        // Periodic time observer
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let t = time.seconds
                if t.isFinite { self.currentTime = t }
            }
        }

        p.play()
        isPlaying = true
    }

    func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
    }

    func skip(_ seconds: Double) {
        guard let p = player else { return }
        let target = p.currentTime().seconds + seconds
        p.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 1000))
    }

    func stop() {
        cleanup()
        trackName = ""
        trackPath = ""
        siblings = []
        currentIndex = 0
        smbClient = nil
    }

    // MARK: - Next / Previous

    var hasNext: Bool { currentIndex < siblings.count - 1 }
    var hasPrevious: Bool { currentIndex > 0 }

    func playNext() { navigate(offset: 1) }
    func playPrevious() { navigate(offset: -1) }

    private func navigate(offset: Int) {
        let newIndex = currentIndex + offset
        guard newIndex >= 0, newIndex < siblings.count else { return }

        let entry = siblings[newIndex]
        currentIndex = newIndex
        let name = (entry.name as NSString).deletingPathExtension

        // SMB: stream
        guard let client = smbClient else { return }
        let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path)
        play(item: item, name: name, path: entry.path,
             siblings: siblings, currentIndex: newIndex, client: client)
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
