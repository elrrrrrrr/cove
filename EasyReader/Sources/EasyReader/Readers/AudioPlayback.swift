import SwiftUI
import Observation

@Observable @MainActor final class AudioPlayback {
    let session = PlaybackSession()
    private(set) var current: ResourceItem?
    private var sequence: [ResourceItem] = []
    private var index = 0
    private var task: Task<Void, Never>?
    private var generation = 0
    private var sources: SourceStore?
    private var library: LibraryStore?
    init() { session.onEnded = { [weak self] in self?.navigate(1) } }
    func play(_ item: ResourceItem, sequence: [ResourceItem], sources: SourceStore, library: LibraryStore) {
        task?.cancel(); session.stop(); generation += 1
        let token = generation
        var audio = sequence.filter { $0.kind == .audio }
        if !audio.contains(where: { $0.id == item.id }) { audio.append(item) }
        self.sequence = audio; index = audio.firstIndex { $0.id == item.id } ?? 0
        self.sources = sources; self.library = library; current = item
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let provider = try? sources.provider(id: item.sourceID)
                let content: ResolvedContent
                if let saved = try ContentResolver.offline(item, library: library) { content = saved }
                else if let provider { content = try await provider.resolve(item) }
                else { throw CoveError.message("音频来源已删除") }
                guard case .media(let asset) = content else { throw CoveError.message("此内容不是音频") }
                try Task.checkCancellation()
                guard generation == token else { return }
                await session.open(item: item, asset: asset, provider: provider, library: library, autoplay: true)
            } catch is CancellationError { }
            catch { if generation == token { session.error = error.localizedDescription } }
        }
    }
    func navigate(_ offset: Int) {
        let next = index + offset
        guard sequence.indices.contains(next), let sources, let library else { return }
        play(sequence[next], sequence: sequence, sources: sources, library: library)
    }
    func toggle() {
        guard let player = session.player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
    }
    func stop() { generation += 1; task?.cancel(); session.stop(); current = nil }
    func stop(sourceID: String) { if current?.sourceID == sourceID { stop() } }
}

struct MiniAudioPlayer: View {
    @Environment(AudioPlayback.self) private var audio
    @State private var showing = false
    var body: some View {
        if let item = audio.current {
            HStack(spacing: 12) {
                Button { showing = true } label: {
                    Label(item.title, systemImage: "music.note").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button("播放或暂停", systemImage: "playpause.fill") { audio.toggle() }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                Button("下一首", systemImage: "forward.end.fill") { audio.navigate(1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                Button("停止", systemImage: "xmark") { audio.stop() }.labelStyle(.iconOnly).frame(width: 44, height: 44)
            }.padding(.horizontal, 16).background(.regularMaterial)
                .sheet(isPresented: $showing) { AudioControls() }
        }
    }
}

struct AudioControls: View {
    @Environment(AudioPlayback.self) private var audio
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    var body: some View {
        VStack(spacing: 24) {
            if let item = audio.current {
                Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary).frame(height: 180)
                Text(item.title).font(.title2).multilineTextAlignment(.center)
                if audio.session.loading { ProgressView() }
                if let error = audio.session.error { Text(error).foregroundStyle(.red) }
                Slider(value: Binding(get: { scrubbing ? scrubValue : audio.session.playhead }, set: { scrubValue = $0 }), in: 0...max(1, audio.session.duration), onEditingChanged: { active in
                    scrubbing = active
                    if !active { audio.session.seek(scrubValue) }
                })
                HStack(spacing: 24) {
                    Button("上一首", systemImage: "backward.end.fill") { audio.navigate(-1) }
                    Button("播放或暂停", systemImage: "playpause.fill") { audio.toggle() }
                    Button("下一首", systemImage: "forward.end.fill") { audio.navigate(1) }
                }.labelStyle(.iconOnly).font(.title).buttonStyle(.bordered)
                Button("停止播放") { audio.stop() }
            } else { ContentUnavailableView("未播放音乐", systemImage: "music.note") }
        }.padding()

    }
}
