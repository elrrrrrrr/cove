import SwiftUI
import SwiftData
import WebKit

// MARK: - Unified Web + NAS Feed Browser

struct FeedView: View {
    enum Source {
        case web(urlString: String, definitionID: String?, bookmark: BookmarkSite?)
        case nas(path: String, client: SMBClient, configID: String, onDisconnect: @MainActor () -> Void)
    }

    let title: String
    let source: Source

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark
    @AppStorage private var savedLayout: String
    @Query private var favorites: [FavoriteVideo]
    @Namespace private var zoomNS

    // Web state
    @State private var session = WebSession()
    @State private var parser: SiteParser
    @State private var activeCategoryURL: String
    @State private var searchText = ""
    @State private var searchExpanded = false
    @State private var searchActiveURL: URL?
    @State private var showWebFallback = false
    @State private var showInspectSheet = false
    @State private var showPageJump = false
    @State private var pageJumpText = ""
    @State private var subFeedTarget: SubFeedTarget?
    @State private var episodeTarget: EpisodeTarget?

    // NAS state
    @State private var nasEntries: [NASFileEntry] = []
    @State private var nasLoading = false
    @State private var nasError: String?
    @State private var nasSubdir: NASSubdirTarget?

    // Shared presentation & chrome state
    @State private var viewerTarget: ViewerTarget?
    @State private var favoriteURLs: Set<String> = []
    @State private var showFloatingBar = true
    @State private var lastScrollY: CGFloat = 0
    @State private var feedbackCount = 0

    init(site: BookmarkSite) {
        self.title = site.name
        self.source = .web(urlString: site.urlString, definitionID: site.definitionID, bookmark: site)
        _parser = State(initialValue: SiteParserRegistry.parser(for: site.urlString, definitionID: site.definitionID))
        _activeCategoryURL = State(initialValue: site.urlString)
        _savedLayout = AppStorage(wrappedValue: "", BrowserLayout.preferenceKey(source: "web", location: site.id.uuidString))
    }

    init(name: String, urlString: String, definitionID: String?) {
        self.title = name
        self.source = .web(urlString: urlString, definitionID: definitionID, bookmark: nil)
        _parser = State(initialValue: SiteParserRegistry.parser(for: urlString, definitionID: definitionID))
        _activeCategoryURL = State(initialValue: urlString)
        _savedLayout = AppStorage(wrappedValue: "", BrowserLayout.preferenceKey(source: "web:\(definitionID ?? "")", location: urlString))
    }

    init(nasTitle: String, path: String, client: SMBClient, configID: String, onDisconnect: @escaping @MainActor () -> Void) {
        self.title = nasTitle
        self.source = .nas(path: path, client: client, configID: configID, onDisconnect: onDisconnect)
        _parser = State(initialValue: .generic)
        _activeCategoryURL = State(initialValue: "")
        _savedLayout = AppStorage(wrappedValue: "", BrowserLayout.preferenceKey(source: "nas:\(configID)", location: path))
    }

    private var layout: BrowserLayout {
        if case .nas = source { return BrowserLayout(rawValue: savedLayout) ?? .list }
        return BrowserLayout(rawValue: savedLayout) ?? parser.galleryLayout
    }

    private var columns: Int {
        switch layout {
        case .list: 1
        case .portrait: hSize == .regular ? 4 : 3
        case .bento: hSize == .regular ? 3 : 2
        }
    }

    var body: some View {
        Group {
            switch source {
            case .web:
                if showWebFallback, let url = session.resolvedBaseURL ?? URL(string: activeCategoryURL) {
                    WebBrowserView(url: url, onClose: { showWebFallback = false })
                } else { webBody }
            case .nas(let path, let client, let configID, _):
                nasBody(path: path, client: client, configID: configID)
            }
        }
        .appSurface(theme)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) { floatingThumbBar }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: feedbackCount)
        .onChange(of: favorites, initial: true) { _, list in favoriteURLs = Set(list.map(\.pageURLString)) }
        .navigationDestination(item: $viewerTarget) { target in
            ResourceRouter(target: target).coveZoomDestination(id: target.id, in: zoomNS)
        }
        .navigationDestination(item: $subFeedTarget) { sub in
            FeedView(name: sub.name, urlString: sub.url.absoluteString, definitionID: parser.definitionID)
        }
        .navigationDestination(item: $nasSubdir) { sub in
            if case .nas(_, let client, let configID, let onDisconnect) = source {
                FeedView(nasTitle: sub.name, path: sub.path, client: client, configID: configID, onDisconnect: onDisconnect)
            }
        }
        .sheet(isPresented: $showInspectSheet) {
            if let req = session.originalRequest ?? URL(string: activeCategoryURL).map({ URLRequest(url: $0) }) {
                ParsingWebViewSheet(webView: session.webView, request: req)
            }
        }
        .sheet(item: $episodeTarget) { target in
            episodeSheet(target)
        }
        .alert("跳转页码", isPresented: $showPageJump) {
            TextField("页码", text: $pageJumpText).keyboardType(.numberPad)
            Button("跳转") { if let p = Int(pageJumpText), p >= 1 { session.loadPage(p) } }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Web Content

    @ViewBuilder
    private var webBody: some View {
        switch session.catalogState {
        case .idle, .loading, .extracting:
            VStack(spacing: 14) {
                ProgressView()
                Text(session.catalogState == .extracting ? "提取内容中…" : "加载网页中…")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("查看原始网页", systemImage: "safari") { showInspectSheet = true }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await startWebLoad() }
        case .failed(let msg):
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.slash")
            } description: { Text(msg) } actions: {
                Button("重试") { session.reload() }.buttonStyle(.borderedProminent)
                Button("网页模式") { showWebFallback = true }
            }
        case .done(let items) where items.isEmpty:
            ContentUnavailableView {
                Label("暂无内容", systemImage: "doc.questionmark")
            } description: { Text("可查看原始网页或切换网页模式") } actions: {
                Button("网页模式") { showWebFallback = true }.buttonStyle(.borderedProminent)
                Button("刷新") { session.reload() }
            }
        case .done(let items):
            scrollCanvas {
                if layout == .bento {
                    BentoGrid(items: items, columns: max(columns, 2)) { item, size in
                        webCard(item, mode: .bento(size), index: items.firstIndex(of: item) ?? 0, count: items.count)
                    } footer: { paginationFooter }
                } else if layout == .portrait {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(columns, 2)), spacing: 12) {
                        Section {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                webCard(item, mode: .portrait, index: idx, count: items.count)
                            }
                        } footer: { paginationFooter }
                    }
                    .padding(.horizontal, 12)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            webCard(item, mode: .list, index: idx, count: items.count)
                        }
                        paginationFooter
                    }
                    .padding(12)
                }
            }
            .refreshable { session.reload() }
            .onDisappear { session.cancel() }
        }
    }

    private func webCard(_ item: ParsedItem, mode: MediaCard.Mode, index: Int, count: Int) -> some View {
        let placeholder = parser.itemKind == .video ? "play.rectangle.fill" : (parser.itemKind == .article ? "doc.text" : "photo.on.rectangle.angled")
        return MediaCard(
            item: item, mode: mode, isFavorited: favoriteURLs.contains(item.pageURL.absoluteString),
            definitionID: parser.definitionID, placeholder: placeholder,
            onExtraTap: parser.searchURLTemplate == nil ? nil : { tag in
                if let url = parser.searchURL(keyword: tag, base: session.resolvedBaseURL ?? URL(string: activeCategoryURL)) {
                    subFeedTarget = SubFeedTarget(name: tag, url: url)
                }
            },
            onTap: {
                feedbackCount += 1
                if parser.itemKind == .navLink {
                    subFeedTarget = SubFeedTarget(name: item.title, url: item.pageURL)
                } else {
                    viewerTarget = .webItem(item, kind: parser.itemKind, definitionID: parser.definitionID, siteName: title)
                }
            }
        )
        .coveZoomSource(id: "web:\(item.pageURL.absoluteString)", in: zoomNS)
        .onAppear {
            if session.canLoadMore, index >= max(0, count - 4) { session.loadNextPage() }
        }
        .contextMenu {
            if parser.itemKind != .navLink {
                let isFav = favoriteURLs.contains(item.pageURL.absoluteString)
                Button(isFav ? "取消收藏" : "收藏", systemImage: isFav ? "heart.slash" : "heart") {
                    toggleFavorite(item)
                }
            }
            if parser.itemKind == .video, let epCount = episodeCount(for: item) {
                Button("选集（\(epCount) 集）", systemImage: "rectangle.stack") {
                    episodeTarget = EpisodeTarget(item: item, count: epCount)
                }
            }
            Button("查看原始网页", systemImage: "safari") { showInspectSheet = true }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if session.paginationFailed {
            Button { session.loadNextPage() } label: {
                Label("加载失败，点击重试", systemImage: "arrow.clockwise").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 56)
        } else if session.canLoadMore || session.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity, minHeight: 56)
                .id("footer-\(session.currentPage)")
                .onAppear { if !session.isLoadingMore { session.loadNextPage() } }
        }
    }

    // MARK: - NAS Directory Content

    @ViewBuilder
    private func nasBody(path: String, client: SMBClient, configID: String) -> some View {
        let filtered = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nasEntries
            : nasEntries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        Group {
            if nasLoading && nasEntries.isEmpty {
                ProgressView("加载目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let nasError {
                ContentUnavailableView { Label("加载失败", systemImage: "exclamationmark.triangle") }
                description: { Text(nasError) }
                actions: { Button("重试") { Task { await loadNAS(path: path, client: client, refresh: true) } } }
            } else if filtered.isEmpty {
                ContentUnavailableView("空目录", systemImage: "folder")
            } else {
                scrollCanvas {
                    if layout == .list {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered) { nasRow($0, client: client, configID: configID) }
                        }.padding(12)
                    } else {
                        let gridItems = filtered.map { entry -> ParsedItem in
                            let u = entry.isDirectory ? URL(string: "cove-dir://\(entry.path)")! :
                                ((entry.fileType == .image || entry.fileType == .video) ? (CoveImagePipeline.smbURL(clientID: client.cacheIdentity, path: entry.path) ?? URL(string: "cove-smb://empty")!) : URL(string: "cove-file://empty")!)
                            return ParsedItem(title: entry.name, pageURL: u,
                                              thumbnail: (!entry.isDirectory && (entry.fileType == .image || entry.fileType == .video)) ? CoveImagePipeline.smbURL(clientID: client.cacheIdentity, path: entry.path) : nil,
                                              duration: entry.displaySize, extra: entry.isDirectory ? "文件夹" : "")
                        }
                        BentoGrid(items: Array(filtered.enumerated()).map { IdentifiedIndex(id: $0.offset, value: $0.element) }, columns: max(columns, 2)) { wrapped, size in
                            MediaCard(item: gridItems[wrapped.id], mode: layout == .portrait ? .portrait : .bento(size),
                                      placeholder: wrapped.value.isDirectory ? "folder.fill" : wrapped.value.fileType.systemImage) {
                                openNASEntry(wrapped.value, client: client, configID: configID)
                            }
                        }
                    }
                }
                .refreshable { await loadNAS(path: path, client: client, refresh: true) }
            }
        }
        .task(id: path) { await loadNAS(path: path, client: client, refresh: false) }
    }

    private func nasRow(_ entry: NASFileEntry, client: SMBClient, configID: String) -> some View {
        Button { openNASEntry(entry, client: client, configID: configID) } label: {
            HStack(spacing: 12) {
                if !entry.isDirectory && (entry.fileType == .image || entry.fileType == .video),
                   let url = CoveImagePipeline.smbURL(clientID: client.cacheIdentity, path: entry.path) {
                    CoveImage(url: url, placeholder: entry.fileType.systemImage)
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: entry.isDirectory ? "folder.fill" : entry.fileType.systemImage)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(entry.isDirectory ? .blue : .accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.subheadline.weight(.medium)).foregroundStyle(theme.textColor).lineLimit(1)
                    if !entry.displaySize.isEmpty { Text(entry.displaySize).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(theme.cardColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SpringPressButtonStyle())
    }

    // MARK: - Thumb-Zone Floating Liquid Glass Bar

    @ViewBuilder
    private var floatingThumbBar: some View {
        let hasCategories = parser.categories.count > 1 && parser.itemKind != .navLink
        let hasSearch = parser.searchURLTemplate != nil || { if case .nas = source { return true }; return false }()
        if showFloatingBar && (hasCategories || hasSearch) && !showWebFallback {
            HStack(spacing: 10) {
                if searchExpanded {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索", text: $searchText)
                            .submitLabel(.search)
                            .onSubmit { runSearch() }
                        Button {
                            withAnimation(.snappy) {
                                searchExpanded = false; searchText = ""
                                if searchActiveURL != nil {
                                    searchActiveURL = nil
                                    reloadCategory(urlString: activeCategoryURL)
                                }
                            }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                } else if hasCategories {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(parser.categories, id: \.urlString) { cat in
                                let active = isCategoryActive(cat)
                                Button {
                                    feedbackCount += 1
                                    selectCategory(cat.urlString)
                                } label: {
                                    Text(cat.name)
                                        .font(.caption.weight(active ? .semibold : .medium))
                                        .foregroundStyle(active ? Color.white : theme.textColor)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                    }
                    .glassEffect(.regular, in: Capsule())
                }
                if hasSearch && !searchExpanded {
                    Button {
                        withAnimation(.snappy) { searchExpanded = true }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .frame(width: 42, height: 42)
                            .glassEffect(.regular, in: Circle())
                    }
                    .buttonStyle(SpringPressButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Helpers & Actions

    private func scrollCanvas<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content().padding(.bottom, 76)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            let delta = y - lastScrollY
            if abs(delta) > 12 {
                withAnimation(.easeInOut(duration: 0.2)) { showFloatingBar = delta < 0 || y < 30 }
                lastScrollY = y
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if case .nas(_, let client, _, let onDisconnect) = source {
                Button("断开") {
                    Task { await client.disconnect() }
                    onDisconnect()
                }
            }
            Menu {
                Picker("布局", selection: Binding(get: { layout }, set: { savedLayout = $0.rawValue })) {
                    ForEach(BrowserLayout.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                if case .web = source {
                    Button("刷新", systemImage: "arrow.clockwise") { session.reload() }
                    Button("跳转页码", systemImage: "number") { pageJumpText = "\(session.currentPage)"; showPageJump = true }
                    Button("查看原始网页", systemImage: "safari") { showInspectSheet = true }
                    Button(showWebFallback ? "返回画廊" : "网页模式", systemImage: "globe") { showWebFallback.toggle() }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func startWebLoad() async {
        guard case .idle = session.catalogState, let url = URL(string: activeCategoryURL) else { return }
        session.loadCatalog(url: url, parser: parser)
    }

    private func isCategoryActive(_ cat: SiteParserCategory) -> Bool {
        activeCategoryURL == cat.urlString || activeCategoryURL.hasSuffix(cat.urlString)
    }

    private func selectCategory(_ rawURL: String) {
        let base = session.resolvedBaseURL ?? URL(string: activeCategoryURL)
        guard let url = WebURLSafety.resolveURL(rawURL, relativeTo: rawURL.hasPrefix("http") ? nil : base) else { return }
        activeCategoryURL = url.absoluteString
        searchActiveURL = nil
        parser = SiteParserRegistry.parser(for: url.absoluteString, definitionID: parser.definitionID)
        session.loadCatalog(url: url, parser: parser, forceRefresh: true)
    }

    private func reloadCategory(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        session.loadCatalog(url: url, parser: parser, forceRefresh: true)
    }

    private func runSearch() {
        guard case .web = source else { return }
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty, let url = parser.searchURL(keyword: kw, base: session.resolvedBaseURL ?? URL(string: activeCategoryURL)) else { return }
        searchActiveURL = url
        session.loadCatalog(url: url, parser: parser, forceRefresh: true)
    }

    private func toggleFavorite(_ item: ParsedItem) {
        let key = item.pageURL.absoluteString
        if let existing = favorites.first(where: { $0.pageURLString == key }) {
            context.delete(existing)
            ToastCenter.shared.show("已取消收藏", icon: "heart.slash")
        } else {
            context.insert(FavoriteVideo(
                title: item.title, pageURLString: key, thumbnailURLString: item.thumbnail?.absoluteString,
                duration: item.duration, siteName: title, isComic: parser.itemKind == .comic,
                isArticle: parser.itemKind == .article, definitionID: parser.definitionID
            ))
            ToastCenter.shared.show("已收藏")
        }
        try? context.save()
    }

    private func episodeCount(for item: ParsedItem) -> Int? {
        guard let field = parser.presentation.episodeCountField else { return nil }
        let value = field == "duration" ? item.duration : (field == "extra" ? item.extra : item.title)
        guard let n = value.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).max(), n > 1 else { return nil }
        return n
    }

    private func episodeSheet(_ target: EpisodeTarget) -> some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                    ForEach(1...target.count, id: \.self) { num in
                        Button("\(num)") {
                            let template = parser.presentation.episodeURLTemplate ?? "{url}"
                            let path = template.replacingOccurrences(of: "{url}", with: target.item.pageURL.absoluteString)
                                .replacingOccurrences(of: "{episode}", with: "\(num)")
                            let url = num == 1 ? target.item.pageURL : (URL(string: path, relativeTo: target.item.pageURL)?.absoluteURL ?? target.item.pageURL)
                            let ep = ParsedItem(title: target.item.title, pageURL: url, thumbnail: target.item.thumbnail,
                                                duration: "第 \(num) 集", extra: target.item.extra, titleImage: target.item.titleImage)
                            episodeTarget = nil
                            viewerTarget = .webItem(ep, kind: .video, definitionID: parser.definitionID, siteName: title)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(theme.cardColor, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding()
            }
            .navigationTitle("选集 · 共 \(target.count) 集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { episodeTarget = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadNAS(path: String, client: SMBClient, refresh: Bool) async {
        nasLoading = nasEntries.isEmpty; nasError = nil
        do {
            nasEntries = try await client.listDirectory(path: path, refresh: refresh)
            nasLoading = false
        } catch {
            if !Task.isCancelled { nasError = error.localizedDescription; nasLoading = false }
        }
    }

    private func openNASEntry(_ entry: NASFileEntry, client: SMBClient, configID: String) {
        if entry.isDirectory {
            nasSubdir = NASSubdirTarget(name: entry.name, path: entry.path)
            return
        }
        if entry.fileType == .audio {
            let siblings = nasEntries.filter { !$0.isDirectory && $0.fileType == .audio }
            viewerTarget = .nasFile(entry, siblings: siblings, index: siblings.firstIndex(of: entry) ?? 0,
                                    clientID: client.cacheIdentity, configID: configID)
            return
        }
        let siblings = nasEntries.filter { !$0.isDirectory && $0.fileType == entry.fileType }
        let idx = siblings.firstIndex(of: entry) ?? 0
        ReadingHistory.recordProgress(in: context, title: (entry.name as NSString).deletingPathExtension,
                                      filePath: entry.path, fileType: entry.fileType, progress: 0, nasConfigID: configID)
        viewerTarget = .nasFile(entry, siblings: siblings, index: idx, clientID: client.cacheIdentity, configID: configID)
    }

    private struct SubFeedTarget: Identifiable, Hashable { let name: String; let url: URL; var id: URL { url } }
    private struct NASSubdirTarget: Identifiable, Hashable { let name: String; let path: String; var id: String { path } }
    private struct EpisodeTarget: Identifiable { let item: ParsedItem; let count: Int; var id: URL { item.pageURL } }
    private struct IdentifiedIndex: Identifiable { let id: Int; let value: NASFileEntry }
}

// MARK: - NAS Root (Server Picker -> FeedView)

struct NASRootView: View {
    @Query private var configs: [NASConfig]
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark

    @State private var connectedClient: SMBClient?
    @State private var connectedConfig: NASConfig?
    @State private var loginTarget: NASConfig?
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let client = connectedClient, let cfg = connectedConfig {
                    FeedView(nasTitle: cfg.name, path: "/", client: client, configID: cfg.id.uuidString) {
                        connectedClient = nil; connectedConfig = nil
                    }
                } else if configs.isEmpty {
                    ContentUnavailableView("未配置 NAS", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text("前往「设置」添加 SMB 连接"))
                        .appSurface(theme)
                        .navigationTitle("NAS")
                } else {
                    List(configs) { cfg in
                        Button { connectTap(cfg) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(cfg.name).font(.headline)
                                    Text(cfg.requiresSMBSetup ? "请到设置完善配置" : "\(cfg.host):\(cfg.port) / \(cfg.shareName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .appSurface(theme)
                    .navigationTitle("NAS")
                }
            }
            .overlay {
                if isConnecting {
                    ProgressView("连接 SMB…").padding(20).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .sheet(item: $loginTarget) { cfg in
                NavigationStack {
                    Form {
                        Section("连接到 \(cfg.name)") { SecureField("密码", text: $password) }
                        Button("连接") {
                            loginTarget = nil
                            if !password.isEmpty { NASKeychain.save(password: password, for: cfg.id) }
                            Task { await performConnect(cfg, password: password) }
                        }
                    }
                    .navigationTitle("NAS 登录")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { loginTarget = nil } } }
                }
            }
            .alert("连接失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func connectTap(_ cfg: NASConfig) {
        guard !cfg.requiresSMBSetup else { error = "请前往「设置」完善 NAS 配置"; return }
        if let saved = NASKeychain.load(for: cfg.id) {
            Task { await performConnect(cfg, password: saved) }
        } else {
            password = ""; loginTarget = cfg
        }
    }

    private func performConnect(_ cfg: NASConfig, password: String) async {
        isConnecting = true
        let smb = SMBClient(snapshot: NASConfigSnapshot(config: cfg))
        do {
            try await smb.connect(password: password)
            connectedClient = smb; connectedConfig = cfg
        } catch {
            self.error = error.localizedDescription
        }
        isConnecting = false
    }
}
