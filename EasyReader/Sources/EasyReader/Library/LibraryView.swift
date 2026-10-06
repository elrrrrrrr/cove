import SwiftUI

struct LibraryView: View {
    var favoritesOnly = true
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var kind: ResourceKind?
    @State private var visible: [ResourceItem] = []
    @State private var selected: ResourceItem?
    @State private var importing = false
    @State private var exporting = false
    @State private var document = TextDocument(text: "", type: .json)
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if visible.isEmpty { ContentUnavailableView(favoritesOnly ? "暂无收藏" : "暂无阅读记录", systemImage: favoritesOnly ? "heart" : "clock") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 18) {
                        ForEach(visible) { item in
                            ResourceCard(item: item, favorite: library.favorites.contains(item.id), read: library.readIDs.contains(item.id), layout: item.kind == .comic || item.kind == .ebook ? "portrait" : "grid",
                                         onOpen: { selected = item },
                                         onFavorite: { do { try library.toggleFavorite(item) } catch { library.error = error.localizedDescription } })
                        }
                    }
                }.padding()
            }
            .navigationTitle(favoritesOnly ? "收藏" : "最近阅读")
            .searchable(text: $query, prompt: "搜索收藏内容")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("内容类型", selection: $kind) {
                            Text("全部").tag(ResourceKind?.none)
                            ForEach(ResourceKind.allCases) { Text($0.label).tag(Optional($0)) }
                        }
                        if favoritesOnly {
                            Button("导入收藏") { importing = true }
                            Button("导出收藏") {
                                do { document = TextDocument(text: String(decoding: try library.exportFavorites(), as: UTF8.self), type: .json); exporting = true }
                                catch { library.error = error.localizedDescription }
                            }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                }
            }
            .task { prepare() }
            .onChange(of: library.favoriteItems) { _, _ in prepare() }
            .onChange(of: library.recentItems) { _, _ in prepare() }
            .onChange(of: query) { _, _ in prepare() }
            .onChange(of: kind) { _, _ in prepare() }
            .fullScreenCover(item: $selected) { item in NavigationStack { ReaderRouter(item: item) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try library.importFavorites(Data(contentsOf: url))
                } catch { library.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "favorites") { result in
                if case .failure(let error) = result { library.error = error.localizedDescription }
            }
        }
    }
    private func prepare() {
        visible = (favoritesOnly ? library.favoriteItems : library.recentItems).filter {
            (kind == nil || $0.kind == kind) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
    }
}
