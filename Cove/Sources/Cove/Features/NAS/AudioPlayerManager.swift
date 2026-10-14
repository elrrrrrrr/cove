import AVFoundation
import Observation
import UIKit

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
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var artwork: UIImage?

    // Sibling navigation context
    private(set) var siblings: [NASFileEntry] = []
    private(set) var currentIndex: Int = 0
    private var smbClient: SMBClient?

    private var durationTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
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

        metadataTask = Task { [weak self] in
            guard let current = p.currentItem else { return }
            let items: [AVMetadataItem]
            if current.externalMetadata.isEmpty {
                items = (try? await current.asset.load(.commonMetadata)) ?? []
            } else { items = current.externalMetadata }
            let metadata = await AudioTrackMetadata.read(items)
            guard !Task.isCancelled else { return }
            let cover: UIImage?
            if let data = metadata.artwork {
                let decoding = Task.detached(priority: .utility) { ImageDecoder.decode(data, sizing: .thumbnail(1024)) }
                cover = await withTaskCancellationHandler(operation: { await decoding.value }, onCancel: { decoding.cancel() })
            } else { cover = nil }
            guard !Task.isCancelled, let self, player === p else { return }
            title = metadata.title; artist = metadata.artist; album = metadata.album; artwork = cover
        }

        // Ignore metadata from a previous track after skip/stop.
        durationTask = Task { [weak self] in
            if let d = try? await p.currentItem?.asset.load(.duration), !Task.isCancelled, let self, player === p {
                let seconds = d.seconds
                if seconds.isFinite { duration = seconds }
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
        let name = (entry.name as NSString).deletingPathExtension

        // SMB: stream
        guard let client = smbClient else { return }
        let item = SMBStreamLoader.makePlayerItem(client: client, remotePath: entry.path)
        play(item: item, name: name, path: entry.path,
             siblings: siblings, currentIndex: newIndex, client: client)
    }

    // MARK: - Cleanup

    func stopIfUsing(client: SMBClient) {
        if smbClient?.cacheIdentity == client.cacheIdentity { stop() }
    }

    private func cleanup() {
        durationTask?.cancel(); durationTask = nil
        metadataTask?.cancel(); metadataTask = nil
        title = ""; artist = ""; album = ""; artwork = nil
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        SMBStreamLoader.cancel(in: player?.currentItem?.asset)
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}

struct AudioTrackMetadata: Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var artwork: Data?

    @MainActor static func read(_ items: [AVMetadataItem]) async -> Self {
        var result = Self()
        for item in items where !Task.isCancelled {
            switch item.commonKey {
            case .commonKeyTitle:
                if result.title.isEmpty { result.title = (try? await item.load(.stringValue)) ?? "" }
            case .commonKeyArtist:
                if result.artist.isEmpty { result.artist = (try? await item.load(.stringValue)) ?? "" }
            case .commonKeyAlbumName:
                if result.album.isEmpty { result.album = (try? await item.load(.stringValue)) ?? "" }
            case .commonKeyArtwork:
                if result.artwork == nil, let data = try? await item.load(.dataValue), data.count <= 4 * 1024 * 1024 { result.artwork = data }
            default: break
            }
        }
        return result
    }
}
