import SwiftUI

/// Item grid for ``SiteGalleryView``: the four gallery layouts (image / list /
/// portrait / bento) plus their card helpers. Extracted verbatim from
/// SiteGalleryView; the parent drives it with values, one binding and callbacks.
struct GalleryItemGrid<Destination: View>: View {
    let items: [ParsedItem]
    @Binding var layout: BrowserLayout
    let columns: Int
    let parser: SiteParser
    let loader: PageLoader
    let automaticImages: Bool
    let savedLayoutIsEmpty: Bool
    @Binding var visibleItemID: UUID?
    let onOpenItem: (ParsedItem) -> Void
    let isFavorited: (ParsedItem) -> Bool
    let onToggleFavorite: (ParsedItem) -> Void
    let onRequestEpisodePicker: (ParsedItem, Int) -> Void
    let extraAction: (ParsedItem) -> ((String) -> Void)?
    let onMixedMediaItem: (ParsedItem) -> Void
    let destination: (ParsedItem) -> Destination

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("gallery-top")
                if savedLayoutIsEmpty && automaticImages {
                    imageGalleryLayout(items)
                } else {
                    switch layout {
                    case .list:
                        listLayout(items)
                    case .portrait:
                        portraitLayout(items)
                    case .bento:
                        bentoLayout(items)
                    }
                }
            }
            .scrollPosition(id: $visibleItemID, anchor: .top)
            .onChange(of: layout) { _, _ in
                if let visibleItemID { proxy.scrollTo(visibleItemID, anchor: .top) }
            }
        }
    }

    // MARK: - Layout: Image gallery (full-width images, e.g. forum thread photos)

    private func imageGalleryLayout(_ items: [ParsedItem]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ThreadImageCard(url: item.thumbnail, index: index, referer: item.pageURL, definitionID: parser.definitionID)
            }
            GalleryInfiniteScrollFooter(loader: loader)
        }
    }

    // MARK: - Layout: List (single-column horizontal cards)

    private func listLayout(_ items: [ParsedItem]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(items) { item in
                Button { onOpenItem(item) } label: { NavLinkCard(item: item, definitionID: parser.definitionID) }
                    .buttonStyle(CardPressStyle())
                    .contextMenu { itemMenu(for: item) }
            }
            GalleryInfiniteScrollFooter(loader: loader)
        }
        .padding(12)
        .scrollTargetLayout()
    }

    // MARK: - Layout: Portrait grid (2:3 cards)

    private func portraitLayout(_ items: [ParsedItem]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
        return Group {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(items) { item in
                    portraitCard(for: item)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            GalleryInfiniteScrollFooter(loader: loader)
        }
    }

    @ViewBuilder
    private func portraitCard(for item: ParsedItem) -> some View {
        if parser.itemKind == .video {
            ZStack(alignment: .topLeading) {
                ComicCard(item: item, isFavorited: isFavorited(item), definitionID: parser.definitionID,
                    onTap: { onOpenItem(item) }, onExtraTap: extraAction(item))

                if let count = listEpisodeCount(for: item) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onRequestEpisodePicker(item, count)
                    } label: {
                        Label("选集 \(count)", systemImage: "rectangle.stack.fill")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 32)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .zIndex(2)
                }
            }
            .contextMenu { favoriteMenuButton(for: item) }
        } else {
            NavigationLink(destination: destination(item)) {
                ComicCard(
                    item: item,
                    isFavorited: isFavorited(item),
                    definitionID: parser.definitionID
                )
            }
            .buttonStyle(CardPressStyle())
            .contextMenu { favoriteMenuButton(for: item) }
        }
    }

    private func listEpisodeCount(for item: ParsedItem) -> Int? {
        guard let field = parser.presentation.episodeCountField else { return nil }
        let value: String
        switch field {
        case "duration": value = item.duration
        case "extra": value = item.extra
        default: value = item.title
        }
        let count = value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .max()
        guard let count, count > 1 else { return nil }
        return count
    }

    // MARK: - Layout: Bento grid (16:9 variable-size cards)

    private func bentoLayout(_ items: [ParsedItem]) -> some View {
        BentoGrid(items: items, columns: columns) { item, cardSize in
            VideoCard(
                item:        item,
                isFavorited: isFavorited(item),
                cardSize:    cardSize,
                definitionID: parser.definitionID,
                onTap: { onOpenItem(item) },
                onLongPress: parser.itemKind == .navLink && parser.presentation.mixedMedia != true ? nil : { handleVideoCardLongPress(item) },
                placeholder: parser.itemKind == .video ? "play.rectangle.fill" : (parser.itemKind == .article ? "doc.text" : "photo.on.rectangle.angled"),
                onExtraTap: extraAction(item)
            )
            .id(item.id)
            .contextMenu { itemMenu(for: item) }
        } footer: {
            GalleryInfiniteScrollFooter(loader: loader)
        }
    }

    // MARK: - Item helpers

    @ViewBuilder private func itemMenu(for item: ParsedItem) -> some View {
        if parser.itemKind != .navLink { favoriteMenuButton(for: item) }
        if parser.itemKind == .video, let count = listEpisodeCount(for: item) {
            Button("选集") { onRequestEpisodePicker(item, count) }
        }
    }

    @ViewBuilder
    private func favoriteMenuButton(for item: ParsedItem) -> some View {
        let isFav = isFavorited(item)
        Button {
            onToggleFavorite(item)
        } label: {
            Label(isFav ? "取消收藏" : "收藏",
                  systemImage: isFav ? "heart.slash" : "heart")
        }
    }

    private func handleVideoCardLongPress(_ item: ParsedItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if parser.presentation.mixedMedia == true {
            onMixedMediaItem(item)
        } else {
            onToggleFavorite(item)
        }
    }
}

/// True when items look like an image gallery (e.g. forum thread with photos)
/// rather than a list of navigation links.
func galleryIsImageContent(_ items: [ParsedItem], parser: SiteParser) -> Bool {
    guard parser.itemKind == .navLink, !items.isEmpty else { return false }
    guard parser.galleryLayout != .portrait else { return false }
    let withThumbs = items.filter { $0.thumbnail != nil }.count
    return withThumbs > items.count / 2
}

/// Infinite-scroll footer: tappable retry on pagination failure, spinner while
/// loading or while more pages are available. Kept visible during loading to
/// avoid the remove/re-add cycle that would retrigger onAppear in a loop.
struct GalleryInfiniteScrollFooter: View {
    let loader: PageLoader

    var body: some View {
        if loader.paginationFailed {
            // Pagination failed — show tappable retry
            Button {
                loader.loadMore()
            } label: {
                Label("加载失败，点击重试", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        } else if loader.canLoadMore || loader.isLoadingMore {
            // Show footer while loading OR when more pages are available.
            // Keeping it visible during loading prevents the remove/re-add cycle
            // that would cause onAppear to fire repeatedly (infinite loop).
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
                .onAppear {
                    guard !loader.isLoadingMore else { return }
                    loader.loadMore()
                }
        }
    }
}
