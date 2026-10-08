import SwiftUI
import SwiftData
import WebKit

struct SiteGalleryView: View {
    let definitionID: String?
    let siteName      : String
    let siteURLString : String
    /// Non-nil when launched from BookmarkSite — used to apply custom JS overrides.
    let bookmarkSite  : BookmarkSite?
    init(site: BookmarkSite) {
        definitionID = site.definitionID
        siteName        = site.name
        siteURLString   = site.urlString
        bookmarkSite    = site
        _loader         = State(wrappedValue: Self.makeLoader())
        _parser = State(initialValue: SiteParserRegistry.parser(for: site.urlString, definitionID: site.definitionID).applying(site.parserOverrides))
        _navigation = State(initialValue: SiteCatalogNavigation(entryURLString: site.urlString))
        _savedLayout = AppStorage(wrappedValue: "", BrowserLayout.preferenceKey(source: "web", location: site.id.uuidString))
    }

    // Sub-site navigation.
    init(name: String, urlString: String, definitionID: String? = nil) {
        self.definitionID = definitionID
        siteName      = name
        siteURLString = urlString
        bookmarkSite  = nil
        _loader       = State(wrappedValue: Self.makeLoader())
        _parser = State(initialValue: SiteParserRegistry.parser(for: urlString, definitionID: definitionID))
        _navigation = State(initialValue: SiteCatalogNavigation(entryURLString: urlString))
        _savedLayout = AppStorage(wrappedValue: "", BrowserLayout.preferenceKey(source: "web:" + (definitionID ?? ""), location: urlString))
    }

    /// Creates a bare PageLoader — cache is pre-populated asynchronously in .task
    /// to avoid a blocking disk read during the view init/State construction.
    private static func makeLoader() -> PageLoader { PageLoader() }

    @State private var loader: PageLoader
    @State private var showWeb          = false
    @State private var showParsingWeb = false
    @State private var showPageInput    = false
    @State private var pageInputText    = ""
    @State private var showJSConfig     = false
    @State private var diagInfo         : String? = nil
    @State private var showDebugSheet   = false
    @State private var extraNavTarget    : ExtraNavItem? = nil
    @State private var videoFullScreen   : ParsedItem? = nil
    @State private var mixedMediaSheetItem: ParsedItem? = nil
    @State private var episodePickerTarget: GalleryEpisodePickerTarget? = nil
    @State private var pendingEpisodeVideo: ParsedItem? = nil
    /// Cached Set so we don't allocate a new one on every body re-evaluation.
    @State private var favoriteURLCache : Set<String> = []
    @State private var navigation: SiteCatalogNavigation
    /// Search
    @State private var searchText       = ""
    @State private var isSearchActive   = false
    @State private var searchUnavailable = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.modelContext) private var modelContext
    @Query private var allFavorites: [FavoriteVideo]

    @State private var library = SiteDefinitionStore.shared
    @State private var parser: SiteParser
    @AppStorage private var savedLayout: String
    @State private var navigationItem: ParsedItem?
    @State private var visibleItemID: UUID?
    @State private var automaticImages = false
    private var layout: BrowserLayout { BrowserLayout(rawValue: savedLayout) ?? parser.galleryLayout }
    private var layoutSelection: Binding<BrowserLayout> {
        Binding(get: { layout }, set: { savedLayout = $0.rawValue })
    }
    private func refreshParser() {
        parser = navigation.parser(definitionID: bookmarkSite?.definitionID ?? definitionID, overrides: bookmarkSite?.parserOverrides)
        guard let url = siteURL else { return }
        loader.load(url: url, parser: parser, forceRefresh: true)
    }
    private var effectiveURLString: String { navigation.categoryURLString }
    private var siteURL: URL? { navigation.currentURL }

    // Grid columns based on gallery layout
    private var columns: Int {
        switch layout {
        case .list:     return 1
        case .portrait: return hSizeClass == .regular ? 4 : 3
        case .bento:    return hSizeClass == .regular ? 3 : 2
        }
    }

    var body: some View {
        Group {
            if showWeb {
                WebReaderView(url: loader.resolvedBaseURL ?? siteURL ?? URL(string: "https://example.com")!,
                              onClose: { showWeb = false })
            } else {
                contentLayer
            }
        }
        .appSurface()
        .navigationTitle(siteName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .safeAreaInset(edge: .bottom) {
            if !showWeb, loader.state.isActive {
                Button("查看原始网页", systemImage: "safari") { showParsingWeb = true }
                    .accessibilityIdentifier("inspect-current-webpage")
                    .buttonStyle(.bordered).padding(10)
                    .frame(maxWidth: .infinity).background(.bar)
            }
        }
        .sheet(isPresented: $showParsingWeb) {
            if let request = loader.originalPageRequest ?? siteURL.map({ URLRequest(url: $0) }) {
                ParsingWebViewSheet(webView: loader.webView, request: request, status: loader.inspectionStatus)
            }
        }
        .task {
            guard let url = siteURL else { return }
            // Async cache pre-warm (disk I/O runs on actor, not main thread)
            if case .idle = loader.state,
               let (cached, _) = await GalleryCache.load(for: parser.cacheURL(for: url)) {
                loader.preload(cached)
            }
            loader.load(url: url, parser: parser)
        }
        // Keep favoriteURLCache in sync — avoids rebuilding a Set<String> on
        // every body re-evaluation (which can happen many times during a load).
        .onChange(of: allFavorites) { _, favorites in
            favoriteURLCache = Set(favorites.map(\.pageURLString))
        }
        .onChange(of: library.definitions) { _, _ in
            refreshParser()
        }
        .onChange(of: bookmarkSite?.customParserConfig) { _, _ in refreshParser() }
        .onChange(of: bookmarkSite?.definitionID) { _, _ in refreshParser() }
        .onChange(of: loader.state, initial: true) { _, state in
            if case .done(let items) = state { automaticImages = isImageContent(items) }
        }
        .navigationDestination(item: $navigationItem) { item in destinationView(for: item) }
        .task(id: "favorites") {
            favoriteURLCache = Set(allFavorites.map(\.pageURLString))
        }
        .searchable(text: $searchText, isPresented: $isSearchActive,
                    placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
        .onSubmit(of: .search) { executeSearch() }
        .onChange(of: isSearchActive) { _, active in
            if !active, navigation.searchURL != nil {
                searchText = ""
                navigation.cancelSearch()
                refreshParser()
            }
        }
        .alert("搜索不可用", isPresented: $searchUnavailable) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请在站点解析规则中配置包含 {keyword} 的搜索地址。")
        }
        .refreshable { await loader.reloadAsync() }
        .alert("跳转到页码", isPresented: $showPageInput) {
            TextField("页码", text: $pageInputText)
                .keyboardType(.numberPad)
            Button("跳转") {
                if let page = Int(pageInputText), page >= 1 {
                    loader.loadPage(page)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前第 \(loader.currentPage) 页")
        }
        .sheet(item: $mixedMediaSheetItem) { item in
            MixedMediaDetailSheet(
                item: item,
                isFavorited: isFavorited(item),
                onToggleFavorite: { toggleFavorite(item) }
            )
        }
        .sheet(item: $episodePickerTarget, onDismiss: openPendingEpisode) { target in
            GalleryEpisodePickerSheet(target: target) { number in
                pendingEpisodeVideo = episodeItem(from: target.item, number: number)
                episodePickerTarget = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .modifier(GalleryNavigationModifier(
            showJSConfig: $showJSConfig,
            showDebugSheet: $showDebugSheet,
            extraNavTarget: $extraNavTarget,
            videoFullScreen: $videoFullScreen,
            bookmarkSite: bookmarkSite,
            loader: loader,
            parser: parser,
            pageURL: siteURL
        ))
    }

    // MARK: - Content

    @ViewBuilder
    private var contentLayer: some View {
        switch loader.state {
        case .idle:
            skeletonGrid

        case .loading:
            skeletonGrid

        case .extracting:
            skeletonGrid
                .overlay(alignment: .top) { extractingBanner }

        case .done(let items) where items.isEmpty:
            emptyView

        case .done(let items):
            itemGrid(items)
                .transition(.opacity)

        case .failed(let msg):
            failureView(msg)
        }
    }

    // MARK: - Item grid

    /// True when items look like an image gallery (e.g. forum thread with photos)
    /// rather than a list of navigation links.
    private func isImageContent(_ items: [ParsedItem]) -> Bool {
        guard parser.itemKind == .navLink, !items.isEmpty else { return false }
        guard parser.galleryLayout != .portrait else { return false }
        let withThumbs = items.filter { $0.thumbnail != nil }.count
        return withThumbs > items.count / 2
    }

    private func itemGrid(_ items: [ParsedItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id("gallery-top")
                if savedLayout.isEmpty && automaticImages {
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
            infiniteScrollFooter
        }
    }

    // MARK: - Layout: List (single-column horizontal cards)

    private func listLayout(_ items: [ParsedItem]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(items) { item in
                Button { openItem(item) } label: { NavLinkCard(item: item, definitionID: parser.definitionID) }
                    .buttonStyle(CardPressStyle())
                    .contextMenu { itemMenu(for: item) }
            }
            infiniteScrollFooter
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
            infiniteScrollFooter
        }
    }

    @ViewBuilder
    private func portraitCard(for item: ParsedItem) -> some View {
        if parser.itemKind == .video {
            ZStack(alignment: .topLeading) {
                ComicCard(item: item, isFavorited: isFavorited(item), definitionID: parser.definitionID,
                    onTap: { openItem(item) }, onExtraTap: extraAction(for: item))

                if let count = listEpisodeCount(for: item) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        episodePickerTarget = GalleryEpisodePickerTarget(item: item, count: count)
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
            NavigationLink(destination: destinationView(for: item)) {
                ComicCard(
                    item: item,
                    isFavorited: favoriteURLCache.contains(item.pageURL.absoluteString),
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

    private func episodeItem(from item: ParsedItem, number: Int) -> ParsedItem {
        let template = parser.presentation.episodeURLTemplate ?? "{url}"
        let path = template.replacingOccurrences(of: "{url}", with: item.pageURL.absoluteString)
            .replacingOccurrences(of: "{episode}", with: String(number))
        let pageURL = number == 1 ? item.pageURL : URL(string: path, relativeTo: item.pageURL)?.absoluteURL ?? item.pageURL
        return ParsedItem(
            title: item.title,
            pageURL: pageURL,
            thumbnail: item.thumbnail,
            duration: "第 \(number) 集",
            extra: item.extra
        )
    }

    private func openPendingEpisode() {
        guard let item = pendingEpisodeVideo else { return }
        pendingEpisodeVideo = nil
        videoFullScreen = item
    }

    // MARK: - Layout: Bento grid (16:9 variable-size cards)

    private func bentoLayout(_ items: [ParsedItem]) -> some View {
        BentoGrid(items: items, columns: columns) { item, cardSize in
            VideoCard(
                item:        item,
                isFavorited: favoriteURLCache.contains(item.pageURL.absoluteString),
                cardSize:    cardSize,
                definitionID: parser.definitionID,
                onTap: { openItem(item) },
                onLongPress: parser.itemKind == .navLink && !isMixedMediaItem(item) ? nil : { handleVideoCardLongPress(item) },
                placeholder: parser.itemKind == .video ? "play.rectangle.fill" : "photo.on.rectangle.angled",
                onExtraTap: extraAction(for: item)
            )
            .id(item.id)
            .contextMenu { itemMenu(for: item) }
        } footer: {
            infiniteScrollFooter
        }
    }

    // MARK: - Destination routing (based on itemKind)

    private func openItem(_ item: ParsedItem) {
        if parser.itemKind == .video { videoFullScreen = item }
        else { navigationItem = item }
    }

    @ViewBuilder private func itemMenu(for item: ParsedItem) -> some View {
        if parser.itemKind != .navLink { favoriteMenuButton(for: item) }
        if parser.itemKind == .video, let count = listEpisodeCount(for: item) {
            Button("选集") { episodePickerTarget = GalleryEpisodePickerTarget(item: item, count: count) }
        }
    }

    @ViewBuilder
    private func destinationView(for item: ParsedItem) -> some View {
        switch parser.itemKind {
        case .navLink:
            SiteGalleryView(name: item.title, urlString: item.pageURL.absoluteString, definitionID: parser.definitionID)
        case .comic:
            ComicDetailView(item: item, definitionID: parser.definitionID)
        case .video:
            VideoDetailView(item: item, definitionID: parser.definitionID)
        }
    }

    // MARK: - Favorites helpers

    @ViewBuilder
    private func favoriteMenuButton(for item: ParsedItem) -> some View {
        let isFav = isFavorited(item)
        Button {
            toggleFavorite(item)
        } label: {
            Label(isFav ? "取消收藏" : "收藏",
                  systemImage: isFav ? "heart.slash" : "heart")
        }
    }

    private func handleVideoCardLongPress(_ item: ParsedItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if isMixedMediaItem(item) {
            mixedMediaSheetItem = item
        } else {
            toggleFavorite(item)
        }
    }

    private func isFavorited(_ item: ParsedItem) -> Bool {
        favoriteURLCache.contains(item.pageURL.absoluteString)
    }

    private func toggleFavorite(_ item: ParsedItem) {
        let key = item.pageURL.absoluteString
        if let existing = allFavorites.first(where: { $0.pageURLString == key }) {
            modelContext.delete(existing)
            favoriteURLCache.remove(key)
        } else {
            let isComic = parser.itemKind == .comic
            modelContext.insert(FavoriteVideo(
                title:              item.title,
                pageURLString:      key,
                thumbnailURLString: item.thumbnail?.absoluteString,
                duration:           item.duration,
                siteName:           siteName,
                isComic:            isComic,
                definitionID:       parser.definitionID
            ))
            favoriteURLCache.insert(key)
        }
    }

    private func isMixedMediaItem(_ item: ParsedItem) -> Bool {
        parser.presentation.mixedMedia == true
    }

    // MARK: - Skeleton (matches gallery layout)

    @ViewBuilder
    private var skeletonGrid: some View {
        switch layout {
        case .bento:
            BentoSkeletonGrid(columns: max(columns, 2))
        case .portrait:
            PortraitSkeletonGrid(columns: columns)
        case .list:
            ListSkeletonView()
        }
    }

    private var extractingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text("提取内容中…").font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .glassEffect(in: Capsule())
        .padding(.top, 8)
    }

    // MARK: - Infinite scroll footer

    @ViewBuilder
    private var infiniteScrollFooter: some View {
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

    // MARK: - Empty / failure

    private var emptyView: some View {
        ContentUnavailableView {
            Label(navigation.searchURL == nil ? "未能提取到内容" : "没有搜索结果", systemImage: "doc.questionmark")
        } description: {
            if let info = diagInfo {
                Text(info).font(.caption2).foregroundStyle(.secondary)
            } else if navigation.searchURL != nil {
                Text("未找到「\(navigation.keyword)」的结果，可查看原始网页确认。")
            } else {
                Text("该站点结构暂不支持，可在完整 WebView 中查看")
            }
        } actions: {
            Button("打开 WebView") { showWeb.toggle() }.buttonStyle(.borderedProminent)
            Button("诊断") { runDiagnostics() }
        }
    }

    private func runDiagnostics() {
        let js = """
        (function() {
            const counts = {};
            ['li','article','div.item','div.col','a[href]','img'].forEach(s => {
                try { counts[s] = document.querySelectorAll(s).length; } catch(e) {}
            });
            return JSON.stringify({ url: window.location.href, title: document.title,
                bodyLen: document.body?.innerHTML?.length || 0, counts });
        })()
        """
        Task {
            if let result = try? await loader.webView.evaluateJavaScript(js) as? String {
                diagInfo = result
            } else {
                diagInfo = "WebView 无响应（可能未加载或被拦截）"
            }
        }
    }

    private func failureView(_ msg: String) -> some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "wifi.slash")
        } description: {
            Text(msg)
        } actions: {
            Button("重试") { loader.reload() }.buttonStyle(.borderedProminent)
            Button("打开 WebView") { showWeb.toggle() }
        }
    }

    // MARK: - Toolbar

    // Category binding for Picker
    private var categorySelection: Binding<String> {
        Binding(
            get: {
                // Return matching category's raw urlString for Picker tag matching
                let active = effectiveURLString
                if let cat = parser.categories.first(where: {
                    $0.urlString == active || active.hasSuffix($0.urlString)
                }) {
                    return cat.urlString
                }
                return active
            },
            set: { newURL in
                // Resolve relative category paths against the WebView's actual domain
                // Handles redirects from a portal to its current content host.
                let resolved: URL?
                if newURL.hasPrefix("http") {
                    resolved = URL(string: newURL)
                } else if let base = loader.resolvedBaseURL ?? URL(string: siteURLString) {
                    resolved = URL(string: newURL, relativeTo: base)?.absoluteURL
                } else {
                    resolved = nil
                }
                guard let url = resolved else { return }
                navigation.selectCategory(url)
                searchText = ""
                refreshParser()
            }
        )
    }

    /// Current category name for status subtitle.
    private var activeCategoryName: String {
        let active = effectiveURLString
        if let cat = parser.categories.first(where: {
            $0.urlString == active || active.hasSuffix($0.urlString)
        }) {
            return cat.name
        }
        return ""
    }

    /// Status subtitle: "60 项 · 中文字幕" or "搜索: keyword" or "加载第3页…"
    private var statusSubtitle: String {
        if parser.itemKind == .navLink { return "" }
        var parts: [String] = []
        if loader.isLoadingMore {
            parts.append("加载第\(loader.currentPage + 1)页…")
        } else if case .done(let items) = loader.state, !items.isEmpty {
            parts.append("\(items.count) 项")
        }
        if parser.categories.count > 1, !activeCategoryName.isEmpty {
            parts.append(activeCategoryName)
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // ── Status subtitle ─────────────────────────────────────
        if !statusSubtitle.isEmpty {
            ToolbarItem(placement: .status) {
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // ── Menu 1: category + jump to page ─────────────────────
        if parser.itemKind != .navLink {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if parser.categories.count > 1 {
                        Picker(activeCategoryName, selection: categorySelection) {
                            ForEach(parser.categories, id: \.urlString) { cat in
                                Text(cat.name).tag(cat.urlString)
                            }
                        }
                        Divider()
                    }
                    Button {
                        pageInputText = "\(loader.currentPage)"
                        showPageInput = true
                    } label: {
                        Label("跳转页码", systemImage: "number")
                    }
                } label: {
                    Image(systemName: "book.pages")
                }
            }
        }
        if !showWeb {
            ToolbarItem(placement: .topBarTrailing) { BrowserLayoutMenu(layout: layoutSelection) }
        }
        // ── Menu 2: tools ───────────────────────────────────────
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("查看原始网页", systemImage: "safari") { showParsingWeb = true }
                    .accessibilityIdentifier("inspect-current-webpage-menu")
                Button { loader.reload() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button { showWeb.toggle() } label: {
                    Label(showWeb ? "解析模式" : "网页模式", systemImage: "safari")
                }
                Divider()
                if bookmarkSite != nil {
                    Button { showJSConfig = true } label: {
                        Label("解析规则", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Button { showDebugSheet = true } label: {
                    Label("解析结果", systemImage: "ant")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("站点工具")
        }
    }

    // MARK: - Search

    /// Build a full search URL from the parser's template and a keyword.
    private func buildSearchURL(keyword: String) -> URL? {
        parser.searchURL(keyword: keyword, base: loader.resolvedBaseURL ?? URL(string: siteURLString))
    }
    private func extraAction(for item: ParsedItem) -> ((String) -> Void)? {
        guard !item.extra.isEmpty, parser.searchURLTemplate != nil else { return nil }
        return { tag in extraNavTarget = extraSearchTarget(for: tag) }
    }

    private func executeSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        guard navigation.search(keyword, parser: parser, base: loader.resolvedBaseURL ?? siteURL) else {
            searchUnavailable = true
            return
        }
        refreshParser()
    }

    // MARK: - Extra tag navigation

    /// Build a search URL on the same site host for the given extra text (e.g. actress name, tag).
    private func extraSearchTarget(for text: String) -> ExtraNavItem? {
        // Use the parser's searchURLTemplate if available
        if let url = buildSearchURL(keyword: text) {
            return ExtraNavItem(name: text, urlString: url.absoluteString)
        }
        return nil
    }
}

/// Lightweight Hashable value for programmatic navigation to an extra-tag page.
struct ExtraNavItem: Identifiable, Hashable {
    let name: String
    let urlString: String
    var id: String { urlString }
}

private struct GalleryEpisodePickerTarget: Identifiable {
    let item: ParsedItem
    let count: Int
    var id: URL { item.pageURL }
}

private struct GalleryEpisodePickerSheet: View {
    let target: GalleryEpisodePickerTarget
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(1...target.count, id: \.self) { number in
                        Button {
                            onSelect(number)
                        } label: {
                            Text("\(number)")
                                .font(.headline.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(number) 集")
                    }
                }
                .padding()
            }
            .appSurface()
            .navigationTitle("选集 · 共 \(target.count) 集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Nav link card (for portal / navigation sites)

struct NavLinkCard: View {
    let item: ParsedItem
    var definitionID: String?

    private var hasThumbnail: Bool { item.thumbnail != nil }

    var body: some View {
        HStack(spacing: 14) {
            // Only show thumbnail area when one exists
            if hasThumbnail {
                CachedThumbnail(url: item.thumbnail, placeholder: "globe", referer: item.pageURL, definitionID: definitionID)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                // Metadata row: extra (author · date) + duration (upvotes, replies, etc.)
                let parts = [item.extra, item.duration].filter { !$0.isEmpty }
                if !parts.isEmpty {
                    Text(parts.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Video card (16:9 thumbnail + metadata)

struct VideoCard: View {
    let item: ParsedItem
    var isFavorited: Bool = false
    var cardSize: BentoCardSize = .small
    var definitionID: String?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var placeholder = "play.rectangle.fill"
    /// Called with the tapped tag string (e.g. actress name, category keyword).
    var onExtraTap: ((String) -> Void)?

    private var titleFont: Font {
        cardSize == .large
            ? .system(size: 15, weight: .semibold)
            : .system(size: 13, weight: .medium)
    }
    private var titleLines: Int { cardSize == .large ? 3 : 2 }
    private var extraFont: Font {
        cardSize == .large
            ? .system(size: 13)
            : .system(size: 11)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailView
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .gesture(cardGesture)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(titleFont)
                    .lineLimit(titleLines)
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                    .gesture(cardGesture)
                if !item.extra.isEmpty {
                    if onExtraTap != nil {
                        extraTagsView
                    } else {
                        Text(item.extra)
                            .font(extraFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .gesture(cardGesture)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .contentShape(Rectangle())
    }

    private var cardGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first(true): onLongPress?()
                case .second: onTap?()
                default: break
                }
            }
    }

    // MARK: - Extra tags

    private var extraTagsView: some View {
        ItemTagLinks(text: item.extra, font: extraFont) { onExtraTap?($0) }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack(alignment: .bottomTrailing) {
            if item.thumbnail != nil {
                CachedThumbnail(url: item.thumbnail, placeholder: placeholder, referer: item.pageURL, definitionID: definitionID)
            } else {
                Color(.secondarySystemBackground)
                    .overlay {
                        Image(systemName: placeholder)
                            .font(.title).foregroundStyle(.tertiary)
                    }
            }
            if !item.duration.isEmpty {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            }
            if !item.duration.isEmpty {
                Text(item.duration)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
            }
            if isFavorited {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.pink)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
}

// MARK: - Skeleton card

struct SkeletonCard: View {
    var isLarge: Bool = false
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(shimmerGradient)
                .aspectRatio(16/9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(shimmerGradient).frame(height: isLarge ? 14 : 12)
                Capsule().fill(shimmerGradient).frame(width: isLarge ? 120 : 80, height: isLarge ? 12 : 10)
                if isLarge {
                    Capsule().fill(shimmerGradient).frame(width: 60, height: 10)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .clipped()
        .onAppear { animateShimmer() }
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(.systemFill), location: phase),
                .init(color: Color(.tertiarySystemFill), location: phase + 0.4),
                .init(color: Color(.systemFill), location: phase + 0.8),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func animateShimmer() {
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            phase = 1.2
        }
    }
}

// MARK: - Portrait skeleton grid (2:3 cards, uniform LazyVGrid)

struct PortraitSkeletonGrid: View {
    let columns: Int
    @State private var phase: CGFloat = -1

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(.systemFill), location: phase),
                .init(color: Color(.tertiarySystemFill), location: phase + 0.4),
                .init(color: Color(.systemFill), location: phase + 0.8),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
        ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(0..<12, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(shimmerGradient)
                            .aspectRatio(2/3, contentMode: .fit)
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(shimmerGradient).frame(height: 12)
                            Capsule().fill(shimmerGradient).frame(width: 60, height: 10)
                        }
                        .padding(.horizontal, 2).padding(.vertical, 5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

// MARK: - List skeleton (horizontal card placeholders)

struct ListSkeletonView: View {
    @State private var phase: CGFloat = -1

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(.systemFill), location: phase),
                .init(color: Color(.tertiarySystemFill), location: phase + 0.4),
                .init(color: Color(.systemFill), location: phase + 0.8),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<8, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(shimmerGradient)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(shimmerGradient).frame(height: 14)
                            Capsule().fill(shimmerGradient).frame(width: 100, height: 11)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(12)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

// MARK: - Thread image card (full-width image for forum thread galleries)

private struct ThreadImageCard: View {
    let url: URL?
    private let source: ThumbnailRequest?
    @Environment(\.displayScale) private var scale
    @State private var pixels = 1024
    private var request: ThumbnailRequest? { source?.resized(.page(width: pixels)) }
    let index: Int

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, index: Int, referer: URL?, definitionID: String?) {
        self.url = url
        self.index = index
        source = url.map { ThumbnailRequest(url: $0, referer: referer, definitionID: definitionID, sizing: .page(width: 1024)) }
        _image = State(initialValue: source.flatMap { ImageMemoryCache.shared.image(for: $0) })
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color(.secondarySystemBackground))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .onGeometryChange(for: Int.self) { [scale] proxy in ImageSizing.pixels(points: proxy.size.width, scale: scale) } action: { pixels = $0 }
        .task(id: request) {
            guard let request else { return }
            failed = false
            let loaded = await ImagePipeline.shared.image(for: request)
            guard !Task.isCancelled else { return }
            if let img = loaded {
                withAnimation(.easeIn(duration: 0.15)) {
                    image = img
                }
            } else {
                failed = true
            }
        }
        .onAppear {
            if image == nil, !failed, let request {
                image = ImageMemoryCache.shared.image(for: request)
            }
        }
        .onDisappear {
            image = nil
        }
    }
}

// MARK: - Parsed items debug sheet

struct ParsedItemsDebugSheet: View {
    let loader: PageLoader
    let parser: SiteParser
    let pageURL: URL?
    @Environment(\.dismiss) private var dismiss

    private var items: [ParsedItem] {
        if case .done(let items) = loader.state { return items }
        return []
    }

    private var stateLabel: String {
        switch loader.state {
        case .idle:            return "空闲"
        case .loading:         return "加载中…"
        case .extracting:      return "提取中…"
        case .done(let items): return "完成（\(items.count) 项）"
        case .failed(let msg): return "失败：\(msg)"
        }
    }

    private var stateIcon: String {
        switch loader.state {
        case .idle:       return "moon.zzz"
        case .loading:    return "arrow.down.circle"
        case .extracting: return "gearshape.2"
        case .done:       return "checkmark.circle.fill"
        case .failed:     return "xmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch loader.state {
        case .idle:       return .secondary
        case .loading:    return .orange
        case .extracting: return .blue
        case .done:       return .green
        case .failed:     return .red
        }
    }

    private var paginationLabel: String {
        switch parser.paginationMode {
        case .none:          return "无"
        case .ajax:          return "AJAX"
        case .webNavigation: return "WebNavigation"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Parse log ──────────────────────────────
                if !loader.parseLog.isEmpty {
                    Section("解析日志") {
                        ForEach(Array(loader.parseLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                // ── Request status ──────────────────────────
                Section("请求状态") {
                    LabeledContent("状态") {
                        Label(stateLabel, systemImage: stateIcon)
                            .foregroundColor(stateColor)
                    }
                    LabeledContent("翻页模式", value: paginationLabel)
                    LabeledContent("当前页", value: "\(loader.currentPage)")
                    LabeledContent("加载翻页中", value: loader.isLoadingMore ? "是" : "否")
                    if case .ajax = parser.paginationMode {
                        LabeledContent("有下一页", value: loader.hasNextPage ? "是" : "否")
                    }
                    if let next = loader.nextPageURL {
                        LabeledContent("下一页 URL") {
                            Text(next.absoluteString)
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }

                Section("页面信息") {
                    LabeledContent("请求 URL") {
                        Text(pageURL?.absoluteString ?? "—")
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let webURL = loader.webView.url, webURL != pageURL {
                        LabeledContent("WebView URL") {
                            Text(webURL.absoluteString)
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    LabeledContent("解析项数", value: "\(items.count)")
                }

                // ── Parsed items ────────────────────────────
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    Section("[\(idx + 1)] \(item.title)") {
                        LabeledContent("pageURL") {
                            Text(item.pageURL.absoluteString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        LabeledContent("thumbnail") {
                            if let thumb = item.thumbnail {
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(thumb.absoluteString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    CachedThumbnail(url: thumb, placeholder: "photo")
                                        .frame(width: 80, height: 50)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            } else {
                                Text("nil")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        if !item.duration.isEmpty {
                            LabeledContent("duration", value: item.duration)
                        }
                        if !item.extra.isEmpty {
                            LabeledContent("extra", value: item.extra)
                        }
                    }
                }
            }
            .appSurface()
            .navigationTitle("解析结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = loader.parseLog.joined(separator: "\n")
                        } label: {
                            Label("复制日志", systemImage: "doc.plaintext")
                        }
                        Button {
                            let text = items.enumerated().map { idx, item in
                                """
                                [\(idx + 1)] \(item.title)
                                pageURL: \(item.pageURL.absoluteString)
                                thumbnail: \(item.thumbnail?.absoluteString ?? "nil")
                                duration: \(item.duration)
                                extra: \(item.extra)
                                """
                            }.joined(separator: "\n---\n")
                            UIPasteboard.general.string = text
                        } label: {
                            Label("复制解析结果", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
            }
        }
    }
}

// MARK: - Mixed media detail sheet

private struct MixedMediaDetailSheet: View {
    let item: ParsedItem
    let isFavorited: Bool
    let onToggleFavorite: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webCoordinator = WebCoordinator()
    @State private var pageTitle = ""
    @State private var isLoading = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebViewRepresentable(
                url: item.pageURL,
                webCoordinator: webCoordinator,
                onTitleChange: { pageTitle = $0 },
                onLoading: { isLoading = $0 }
            )
            .ignoresSafeArea()
            .padding(.top, 52)
                .padding(.bottom, 86)

            VStack(spacing: 0) {
                topBar
                Spacer()
                favoriteBar
            }
        }
        .task {
            await webCoordinator.loadBlocker()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            if isLoading { ProgressView().scaleEffect(0.8) }
            Text(navTitle)
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var navTitle: String {
        pageTitle.isEmpty ? item.title : pageTitle
    }

    private var favoriteBar: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onToggleFavorite()
        } label: {
            Label(isFavorited ? "取消收藏" : "收藏",
                  systemImage: isFavorited ? "heart.fill" : "heart")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isFavorited ? .pink : .accentColor)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Card press style (scale-down feedback on tap)

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Navigation modifier (extracted to reduce body complexity)

private struct GalleryNavigationModifier: ViewModifier {
    @Binding var showJSConfig: Bool
    @Binding var showDebugSheet: Bool
    @Binding var extraNavTarget: ExtraNavItem?
    @Binding var videoFullScreen: ParsedItem?
    let bookmarkSite: BookmarkSite?
    /// Derived flag — drives fullScreenCover(isPresented:) for reliability.
    private var isVideoPresented: Binding<Bool> {
        Binding(
            get: { videoFullScreen != nil },
            set: { if !$0 { videoFullScreen = nil } }
        )
    }
    let loader: PageLoader
    let parser: SiteParser
    let pageURL: URL?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showJSConfig) {
                if let site = bookmarkSite {
                    SiteConfigSheet(site: site)
                }
            }
            .navigationDestination(item: $extraNavTarget) { target in
                SiteGalleryView(name: target.name, urlString: target.urlString, definitionID: parser.definitionID)
            }
            .sheet(isPresented: $showDebugSheet) {
                ParsedItemsDebugSheet(loader: loader, parser: parser, pageURL: pageURL)
            }
            .fullScreenCover(isPresented: isVideoPresented) {
                if let item = videoFullScreen {
                    VideoDetailView(item: item, definitionID: parser.definitionID)
                }
            }
    }
}
