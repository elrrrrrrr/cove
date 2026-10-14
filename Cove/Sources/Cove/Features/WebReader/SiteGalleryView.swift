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
        .toolbar {
            GalleryToolbar(
                parser: parser,
                loader: loader,
                bookmarkSite: bookmarkSite,
                siteURLString: siteURLString,
                navigation: $navigation,
                searchText: $searchText,
                showParsingWeb: $showParsingWeb,
                showWeb: $showWeb,
                showPageInput: $showPageInput,
                pageInputText: $pageInputText,
                showJSConfig: $showJSConfig,
                showDebugSheet: $showDebugSheet,
                layout: layoutSelection,
                onRefreshParser: refreshParser
            )
        }
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
            if case .done(let items) = state { automaticImages = galleryIsImageContent(items, parser: parser) }
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
            GalleryItemGrid(
                items: items,
                layout: layoutSelection,
                columns: columns,
                parser: parser,
                loader: loader,
                automaticImages: automaticImages,
                savedLayoutIsEmpty: savedLayout.isEmpty,
                visibleItemID: $visibleItemID,
                onOpenItem: openItem,
                isFavorited: isFavorited,
                onToggleFavorite: toggleFavorite,
                onRequestEpisodePicker: { item, count in
                    episodePickerTarget = GalleryEpisodePickerTarget(item: item, count: count)
                },
                extraAction: extraAction,
                onMixedMediaItem: { mixedMediaSheetItem = $0 },
                destination: { destinationView(for: $0) }
            )
            .transition(.opacity)

        case .failed(let msg):
            failureView(msg)
        }
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


    // MARK: - Destination routing (based on itemKind)

    private func openItem(_ item: ParsedItem) {
        if parser.itemKind == .video { videoFullScreen = item }
        else { navigationItem = item }
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
        case .article:
            ArticleReaderView(item: item, definitionID: parser.definitionID)
        }
    }

    // MARK: - Favorites helpers


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
                isArticle:          parser.itemKind == .article,
                definitionID:       parser.definitionID
            ))
            favoriteURLCache.insert(key)
        }
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


