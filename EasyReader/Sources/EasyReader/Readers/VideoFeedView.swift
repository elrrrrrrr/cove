import SwiftUI
import AVKit
import Observation

@Observable @MainActor private final class VideoFeedModel {
    private(set) var sequence: [ResourceItem] = []
    private(set) var displaySequence: [ResourceItem] = []
    var activeID: String?
    var error: String?
    let session = PlaybackSession()
    let browser: BrowserModel
    private var task: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var generation = 0
    private var currentAsset: MediaAsset?
    private var ready: [String: (date: Date, asset: MediaAsset)] = [:]
    private let settings: FeedPresentation
    private let library: LibraryStore

    init(item: ResourceItem, browser: BrowserModel, library: LibraryStore) {
        self.browser = browser; self.library = library
        settings = browser.provider.definition.presentation?.feed ?? FeedPresentation()
        activeID = item.id
        updateSequence()
    }
    func updateSequence() {
        sequence = browser.visible.filter { $0.kind == .video }
        displaySequence = settings.nextGesture == "swipeDown" ? sequence.reversed() : sequence
    }
    func activate(_ id: String?) {
        task?.cancel(); prefetch?.cancel(); session.stop()
        generation += 1; error = nil; currentAsset = nil
        guard let id, let item = sequence.first(where: { $0.id == id }) else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let asset: MediaAsset
                if let cached = ready[id], Date.now.timeIntervalSince(cached.date) < 30 { asset = cached.asset }
                else if case .media(let resolved) = try await browser.provider.resolve(item) { asset = resolved }
                else { throw CoveError.message("此内容无法作为视频播放") }
                try Task.checkCancellation()
                guard token == generation else { return }
                currentAsset = asset
                await session.open(item: item, asset: asset, provider: browser.provider, library: library, autoplay: settings.autoplay ?? true)
                if let index = sequence.firstIndex(where: { $0.id == id }), index >= sequence.count - 2 {
                    await browser.loadMore()
                    guard token == generation else { return }
                    updateSequence()
                }
                prepareNext(after: id)
            } catch is CancellationError { }
            catch { if token == generation { self.error = error.localizedDescription } }
        }
    }
    private func prepareNext(after id: String) {
        guard settings.preloadNext != 0, let index = sequence.firstIndex(where: { $0.id == id }),
              sequence.indices.contains(index + 1) else { return }
        let next = sequence[index + 1]
        ready = ready.filter { $0.key == id || $0.key == next.id }
        prefetch = Task { [weak self] in
            guard let self else { return }
            do {
                if case .media(let asset) = try await browser.provider.resolve(next), !Task.isCancelled {
                    ready[next.id] = (.now, asset)
                }
            } catch { }
        }
    }
    func playbackEnded() {
        if settings.onPlaybackEnd == "nextItem", let id = activeID,
           let index = sequence.firstIndex(where: { $0.id == id }), sequence.indices.contains(index + 1) {
            activeID = sequence[index + 1].id
        }
        if settings.onPlaybackEnd == "nextEpisode", let id = activeID, let index = sequence.firstIndex(where: { $0.id == id }),
           let next = currentAsset?.nextEpisode {
            sequence[index] = next
            displaySequence = settings.nextGesture == "swipeDown" ? sequence.reversed() : sequence
            activeID = next.id
        }
    }
    func close() { generation += 1; task?.cancel(); prefetch?.cancel(); session.stop() }
}

struct VideoFeedView: View {
    let item: ResourceItem
    let browser: BrowserModel
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayback.self) private var audio
    @Environment(\.dismiss) private var dismiss
    @State private var model: VideoFeedModel?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let model {
                @Bindable var model = model
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.displaySequence) { video in
                            ZStack(alignment: .bottomLeading) {
                                if model.activeID == video.id {
                                    VideoPlayer(player: model.session.player)
                                        .accessibilityIdentifier("feed.player")
                                        .accessibilityValue(model.session.isPlaying ? "正在播放" : "已暂停")
                                    if model.session.loading { ProgressView().tint(.white) }
                                    if let error = model.session.error ?? model.error { Text(error).foregroundStyle(.white).padding() }
                                } else { ResourceThumbnail(item: video).scaledToFit() }
                                HStack {
                                    Text(video.title).foregroundStyle(.white).lineLimit(2)
                                    Spacer()
                                    Button {
                                        do { try library.toggleFavorite(video) } catch { library.error = error.localizedDescription }
                                    } label: {
                                        Image(systemName: library.favorites.contains(video.id) ? "heart.fill" : "heart")
                                            .foregroundStyle(.white).frame(width: 44, height: 44)
                                    }
                                }.padding(20).padding(.bottom, 28).background(.black.opacity(0.4))
                            }
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(video.id)
                        }
                    }.scrollTargetLayout()
                }
                .scrollIndicators(.hidden).scrollTargetBehavior(.paging)
                .scrollPosition(id: $model.activeID).ignoresSafeArea()
                .onChange(of: model.activeID) { _, id in model.activate(id) }
                .onChange(of: model.session.ended) { _, ended in if ended { model.playbackEnded() } }
            }
            Button { model?.close(); dismiss() } label: {
                Image(systemName: "xmark").foregroundStyle(.white).frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle())
            }.accessibilityLabel("关闭播放").accessibilityIdentifier("feed.close").padding()
        }
        .task {
            audio.session.player?.pause()
            let next = VideoFeedModel(item: item, browser: browser, library: library)
            model = next; next.activate(item.id)
        }
        .onDisappear { model?.close() }
    }
}
