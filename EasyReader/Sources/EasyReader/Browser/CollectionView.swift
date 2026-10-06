import SwiftUI

struct CollectionView: View {
    let sourceID: String
    let locator: String
    let title: String
    @Environment(SourceStore.self) private var sources
    @Environment(LibraryStore.self) private var library
    @Environment(OfflineService.self) private var offline
    @State private var model: BrowserModel?
    @State private var error: String?
    @State private var selected: ResourceItem?
    @State private var episodes: ResourceItem?
    @State private var singleEpisode = false
    @State private var folder: ResourceItem?
    @State private var browserURL: URL?
    @State private var layout = "grid"
    @State private var searchText = ""
    var body: some View {
        Group {
            if let model { content(model) }
            else if let error { ContentUnavailableView("无法打开来源", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("正在打开来源…") }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sources.revisions[sourceID]) {
            do {
                let provider = try sources.provider(id: sourceID)
                let next = BrowserModel(provider: provider, locator: locator)
                layout = provider.definition.presentation?.layout ?? "grid"
                model = next; await next.load()
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $browserURL, onDismiss: { sources.invalidateSession(id: sourceID) }) { url in OriginalWebView(url: url, sourceID: sourceID) }
        .navigationDestination(item: $folder) { CollectionView(sourceID: sourceID, locator: $0.locator, title: $0.title) }
        .sheet(item: $episodes) { item in
            if let config = model?.provider.definition.modules?.episodes { EpisodePicker(item: item, config: config) { selected in singleEpisode = true; self.selected = selected } }
        }
        .fullScreenCover(item: $selected, onDismiss: { singleEpisode = false }) { item in
            if !singleEpisode, let model, item.kind == .video, model.provider.definition.presentation?.openItem == "videoFeed" {
                VideoFeedView(item: item, browser: model)
            } else { NavigationStack { ReaderRouter(item: item, sequence: model?.visible ?? []) } }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("列表布局", selection: $layout) {
                        Text("网格").tag("grid"); Text("封面").tag("portrait"); Text("列表").tag("list")
                    }
                    if let source = sources.definition(id: sourceID), source.source.adapter == .web {
                        Button("查看原始网页", systemImage: "safari") { browserURL = source.absoluteURL(locator) }
                        if let login = source.modules?.login {
                            Button("登录来源", systemImage: "person.crop.circle") { browserURL = source.absoluteURL(login.url) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
    private func content(_ model: BrowserModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let error = model.error {
                    VStack { Text(error).font(.subheadline); Button("重试") { Task { await model.load(force: true) } } }.padding()
                }
                if model.loading && model.items.isEmpty { ProgressView("正在加载内容…").padding(.top, 80) }
                else if model.visible.isEmpty { ContentUnavailableView("没有内容", systemImage: "square.grid.2x2", description: Text("尝试搜索、登录或检查列表规则")) }
                else {
                    LazyVGrid(columns: layout == "list" ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: layout == "portrait" ? 140 : 160), spacing: 12)], spacing: 18) {
                        ForEach(model.visible) { item in
                            ResourceCard(item: item, favorite: library.favorites.contains(item.id),
                                read: library.readIDs.contains(item.id), layout: layout,
                                onOpen: { if item.kind == .folder { folder = item } else { selected = item } },
                                onFavorite: { do { try library.toggleFavorite(item) } catch { library.error = error.localizedDescription } },
                                onTag: model.provider.definition.modules?.search == nil ? nil : { tag in searchText = tag },
                                onEpisodes: item.episodeCount == nil || model.provider.definition.modules?.episodes == nil ? nil : { episodes = item })
                            .contextMenu { Button("离线保存", systemImage: "arrow.down.circle") { offline.start(item, sources: sources, library: library) }.disabled(item.kind == .folder) }

                        }
                    }
                }
                if model.nextCursor != nil {
                    Button { Task { await model.loadMore() } } label: {
                        if model.loadingMore { ProgressView() } else { Text("加载更多") }
                    }.buttonStyle(.bordered).padding(.vertical)
                }
            }.padding()
        }
        .searchable(text: $searchText, prompt: model.provider.definition.modules?.search != nil ? "搜索来源" : "筛选当前列表")
        .onChange(of: searchText) { _, value in model.setQuery(value) }
        .refreshable { await model.load(force: true) }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
