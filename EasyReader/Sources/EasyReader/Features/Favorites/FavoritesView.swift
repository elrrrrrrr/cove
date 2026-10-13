import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Query(sort: \FavoriteVideo.addedAt, order: .reverse)
    private var favorites: [FavoriteVideo]

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var document = JSONDataDocument()
    @State private var transferError: String?
    @State private var showPinManager = false

    private var columns: Int { hSizeClass == .regular ? 3 : 2 }

    private var filtered: [FavoriteVideo] {
        guard !searchText.isEmpty else { return favorites }
        let query = searchText.lowercased()
        return favorites.filter {
            $0.title.lowercased().contains(query) ||
            $0.siteName.lowercased().contains(query)
        }
    }

    var body: some View {
        let items = filtered
        let pinned = FavoritePins.ordered(items)
        let videoFavs = items.filter { !$0.isPinned && !$0.isComic && !$0.isArticle }
        let comicFavs = items.filter { !$0.isPinned && $0.isComic }
        let articleFavs = items.filter { !$0.isPinned && $0.isArticle }

        NavigationStack {
            Group {
                if favorites.isEmpty {
                    emptyState
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    grid(pinned: pinned, videoFavs: videoFavs, comicFavs: comicFavs, articleFavs: articleFavs)
                }
            }
            .appSurface()
            .navigationTitle("收藏")
            .searchable(text: $searchText, prompt: "搜索标题或站点")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("管理置顶", systemImage: "pin") { showPinManager = true }.disabled(favorites.isEmpty)
                        Divider()
                        Button("导入收藏（合并）", systemImage: "square.and.arrow.down") { showImporter = true }
                        Button("导出收藏", systemImage: "square.and.arrow.up") {
                            do { document = JSONDataDocument(data: try FavoriteDataFile.export(favorites).json()); showExporter = true }
                            catch { transferError = error.localizedDescription }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("收藏工具")
                }
            }
            .sheet(isPresented: $showPinManager) { FavoritePinsView() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try FavoriteDataFile.decode(Data(contentsOf: url)).apply(to: context)
                    try context.save()
                } catch { context.rollback(); transferError = error.localizedDescription }
            }
            .fileExporter(isPresented: $showExporter, document: document, contentType: .json, defaultFilename: "favorites.json") { result in
                if case .failure(let error) = result { transferError = error.localizedDescription }
            }
            .alert("收藏操作失败", isPresented: Binding(get: { transferError != nil }, set: { if !$0 { transferError = nil } })) {
                Button("好") { transferError = nil }
            } message: { Text(transferError ?? "") }
        }
    }

    // MARK: - Grid

    private func grid(pinned: [FavoriteVideo], videoFavs: [FavoriteVideo], comicFavs: [FavoriteVideo], articleFavs: [FavoriteVideo]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !pinned.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("置顶", systemImage: "pin.fill").font(.headline).foregroundColor(.accentColor)
                        ForEach(pinned) { fav in
                            if let url = fav.pageURL {
                                NavigationLink {
                                    FavoriteDestination(favorite: fav, url: url)
                                } label: {
                                    FavoritePinRow(favorite: fav).padding(12)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(fav.title)
                                .accessibilityValue("已置顶")
                                .contextMenu { favoriteActions(fav) }
                            }
                        }
                    }.padding(.horizontal, 12).padding(.top, 10)
                }
                if !articleFavs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("图文").font(.headline)
                        ForEach(articleFavs) { favorite in
                            if let url = favorite.pageURL {
                                NavigationLink { FavoriteDestination(favorite: favorite, url: url) } label: {
                                    FavoritePinRow(favorite: favorite).padding(12)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).contextMenu { favoriteActions(favorite) }
                            }
                        }
                    }.padding(.horizontal, 12)
                }
                // Video favorites
                if !videoFavs.isEmpty {
                    BentoGrid(items: videoFavs, columns: columns) { fav, cardSize in
                        if let pageURL = fav.pageURL {
                            NavigationLink(destination: VideoDetailView(item: ParsedItem(
                                title: fav.title,
                                pageURL: pageURL,
                                thumbnail: fav.thumbnailURL,
                                duration: fav.duration,
                                extra: fav.siteName
                            ), definitionID: fav.definitionID)) {
                                FavoriteCard(fav: fav, cardSize: cardSize)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(fav.title)
                            .contextMenu { favoriteActions(fav) }
                        }
                    }
                }

                // Comic favorites
                if !comicFavs.isEmpty {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 10),
                                    count: hSizeClass == .regular ? 4 : 3)
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(comicFavs) { fav in
                            if let pageURL = fav.pageURL {
                                NavigationLink(destination: ComicDetailView(item: ParsedItem(
                                    title: fav.title,
                                    pageURL: pageURL,
                                    thumbnail: fav.thumbnailURL,
                                    duration: "",
                                    extra: fav.siteName
                                ), definitionID: fav.definitionID)) {
                                    ComicCard(
                                        item: ParsedItem(
                                            title: fav.title,
                                            pageURL: pageURL,
                                            thumbnail: fav.thumbnailURL,
                                            duration: "",
                                            extra: fav.siteName
                                        ),
                                        isFavorited: true, definitionID: fav.definitionID
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(fav.title)
                                .contextMenu { favoriteActions(fav) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    @ViewBuilder private func favoriteActions(_ favorite: FavoriteVideo) -> some View {
        Button(favorite.isPinned ? "取消置顶" : "置顶", systemImage: favorite.isPinned ? "pin.slash" : "pin") {
            do { try FavoritePins.set(favorite, pinned: !favorite.isPinned, context: context) }
            catch { transferError = error.localizedDescription }
        }
        Button("取消收藏", systemImage: "heart.slash", role: .destructive) {
            context.delete(favorite)
            do { try context.save() }
            catch { context.rollback(); transferError = error.localizedDescription }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无收藏", systemImage: "heart")
        } description: {
            Text("长按内容卡片可添加收藏")
        }
    }
}

private struct FavoriteDestination: View {
    let favorite: FavoriteVideo
    let url: URL
    var body: some View {
        let item = ParsedItem(title: favorite.title, pageURL: url, thumbnail: favorite.thumbnailURL, duration: favorite.duration, extra: favorite.siteName)
        switch favorite.contentKind {
        case .article: ArticleReaderView(item: item, definitionID: favorite.definitionID)
        case .comic: ComicDetailView(item: item, definitionID: favorite.definitionID)
        case .video, .navLink: VideoDetailView(item: item, definitionID: favorite.definitionID)
        }
    }
}

// MARK: - Favorite card (same layout as VideoCard)

struct FavoriteCard: View {
    let fav: FavoriteVideo
    var cardSize: BentoCardSize = .small

    private var titleFont: Font {
        cardSize == .large
            ? .system(size: 15, weight: .semibold)
            : .system(size: 13, weight: .medium)
    }
    private var titleLines: Int { cardSize == .large ? 3 : 2 }
    private var extraFont: Font {
        cardSize == .large ? .system(size: 13) : .system(size: 11)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                CachedThumbnail(url: fav.thumbnailURL, placeholder: "play.rectangle.fill", referer: fav.pageURL, definitionID: fav.definitionID)

                if !fav.duration.isEmpty {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .center, endPoint: .bottom)
                    Text(fav.duration)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(fav.title)
                    .font(titleFont)
                    .lineLimit(titleLines)
                    .foregroundStyle(.primary)
                if !fav.siteName.isEmpty {
                    Text(fav.siteName)
                        .font(extraFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }
}
