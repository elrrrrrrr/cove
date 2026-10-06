import SwiftUI
import AVKit

struct ReaderRouter: View {
    let item: ResourceItem
    var sequence: [ResourceItem] = []
    @Environment(SourceStore.self) private var sources
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var providerLease: (any SourceProvider)?
    @State private var resolved: ResolvedContent?
    @State private var history: LibraryEntry?
    @State private var error: String?
    var body: some View {
        Group {
            if let resolved, let history { destination(resolved, history: history) }
            else if let error { ContentUnavailableView("无法打开内容", systemImage: item.kind.icon, description: Text(error)) }
            else { ProgressView("正在打开内容…") }
        }
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .task(id: item.id + (sources.revisions[item.sourceID] ?? "")) {
            do {
                let result: ResolvedContent
                if let saved = try ContentResolver.offline(item, library: library) { result = saved }
                else {
                    let provider = try sources.provider(id: item.sourceID)
                    providerLease = provider
                    result = try await provider.resolve(item)
                }
                try Task.checkCancellation()
                history = try library.opened(item); resolved = result
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    @ViewBuilder private func destination(_ content: ResolvedContent, history: LibraryEntry) -> some View {
        switch content {
        case .collection(let locator): CollectionView(sourceID: item.sourceID, locator: locator, title: item.title)
        case .web(let url): OriginalWebView(url: url, sourceID: item.sourceID, history: history)
        case .document(let url):
            switch url.pathExtension.lowercased() {
            case "pdf": PDFReaderView(fileURL: url, title: item.title, historyItem: history)
            case "epub": EPUBReaderView(fileURL: url, title: item.title, historyItem: history)
            case "txt": TXTReaderView(fileURL: url, title: item.title, historyItem: history)
            default: ContentUnavailableView("暂不支持此格式", systemImage: "doc", description: Text("可以在其他 App 中打开此文件"))
            }
        case .image(let url): ImageReader(item: item, url: url)
        case .comic(let content): ComicReader(item: item, content: content, history: history)
        case .media(let asset): SingleMediaView(item: item, asset: asset, sequence: sequence)
        }
    }
}

private struct SingleMediaView: View {
    let item: ResourceItem
    let asset: MediaAsset
    var sequence: [ResourceItem]
    @Environment(AudioPlayback.self) private var audio
    @Environment(SourceStore.self) private var sources
    @Environment(LibraryStore.self) private var library
    @State private var session = PlaybackSession()
    @State private var episode: ResourceItem?
    var body: some View {
        Group {
            if item.kind == .audio { AudioControls() }
            else { video }
        }.task {
            if item.kind == .audio, audio.current?.id != item.id { audio.play(item, sequence: sequence, sources: sources, library: library) }
        }
    }
    private var video: some View {
        VStack(spacing: 20) {
            if item.kind == .audio { ResourceThumbnail(item: item).aspectRatio(1, contentMode: .fit).frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 20)) }
            VideoPlayer(player: session.player).frame(maxHeight: item.kind == .audio ? 100 : .infinity)
            if session.loading { ProgressView("正在准备播放…") }
            if let error = session.error { Text(error).foregroundStyle(.red) }
            if let next = asset.nextEpisode { Button("下一集") { session.stop(); episode = next } }
        }.padding(item.kind == .audio ? 20 : 0)
        .task {
            audio.session.player?.pause()
            await session.open(item: item, asset: asset, provider: try? sources.provider(id: item.sourceID), library: library, autoplay: true)
        }
        .onDisappear { session.stop() }
        .navigationDestination(item: $episode) { ReaderRouter(item: $0) }
    }
}

private struct ImageReader: View {
    let item: ResourceItem
    let url: URL
    @Environment(SourceStore.self) private var sources
    @State private var image: UIImage?
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1200) }
            else { ProgressView() }
        }.task {
            let request = ImageRequest(url: url, sourceID: item.sourceID, sourceRevision: sources.revisions[item.sourceID] ?? "", assetRevision: item.revision, pixels: 2400, headers: ["Referer": item.locator], transform: sources.definition(id: item.sourceID)?.modules?.images)
            let prepared = await SourceWebSession.imageRequest(request)
            image = await ImagePipeline.shared.image(prepared)?.image
        }
    }
}
