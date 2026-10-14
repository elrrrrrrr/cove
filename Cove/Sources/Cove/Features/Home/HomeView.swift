import SwiftUI
import SwiftData

struct HomeView: View {
    var downloadManager: DownloadManager = .shared
    @State private var historyIndex = ReadingIndex()

    @Query(sort: \BookmarkSite.sortOrder)
    private var sites: [BookmarkSite]

    @Query(sort: \OfflineItem.savedAt, order: .reverse)
    private var offlineItems: [OfflineItem]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @AppStorage("home.quickAccess.collapsed") private var quickAccessCollapsed = false
    @AppStorage("home.recent.collapsed")      private var recentCollapsed = false
    @AppStorage("home.offline.collapsed")     private var offlineCollapsed = false

    private var columns: Int { hSizeClass == .regular ? 3 : 2 }

    private var recentHistory: [ReadingHistory] { Array(historyIndex.recent.prefix(hSizeClass == .regular ? 12 : 5)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {

                    // ── 快速访问站点 ──────────────────────────────────
                    if !sites.isEmpty {
                        collapsibleHeader("快速访问", collapsed: $quickAccessCollapsed)
                        if !quickAccessCollapsed { quickAccessRow }
                    }

                    // ── 继续阅读 ──────────────────────────────────────
                    if let latest = historyIndex.latest {
                        sectionHeader("继续阅读")
                        continueReadingCard(latest)
                    }

                    // ── 最近阅读 ──────────────────────────────────────
                    if !recentHistory.isEmpty {
                        collapsibleHeader("最近阅读", collapsed: $recentCollapsed)
                        if !recentCollapsed { recentRow }
                    }

                    // ── 下载中 ──────────────────────────────────────
                    ActiveDownloadsSection(manager: downloadManager)

                    // ── 稍后再看 ──────────────────────────────────────
                    if !offlineItems.isEmpty {
                        collapsibleHeader("稍后再看", collapsed: $offlineCollapsed)
                        if !offlineCollapsed { offlineList }
                    }

                    // ── 空状态 ────────────────────────────────────────
                    if sites.isEmpty && historyIndex.latest == nil {
                        emptyState
                    }
                }
                .padding(.vertical)
            }
            .background(ReadingIndexObserver(index: historyIndex).equatable())
            .appSurface()
            .navigationTitle("主页")
        }
    }

    // MARK: - Quick access

    @ViewBuilder
    private var quickAccessRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 14)], spacing: 14) {
            ForEach(sites) { site in
                NavigationLink(destination: SiteGalleryView(site: site)) {
                    SiteQuickCard(site: site)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Continue reading card

    private func continueReadingCard(_ item: ReadingHistory) -> some View {
        NavigationLink(destination: destinationView(for: item)) {
            HStack(spacing: 14) {
                thumbnailView(item)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    ProgressView(value: item.progress)
                        .tint(.accentColor)
                    Text("\(Int(item.progress * 100))% · \(item.lastReadAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    // MARK: - Recent horizontal scroll

    private var recentRow: some View {
        BentoGrid(items: recentHistory, columns: columns) { item, cardSize in
            NavigationLink(destination: destinationView(for: item)) {
                RecentCard(item: item, cardSize: cardSize)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    modelContext.delete(item)
                } label: {
                    Label("删除记录", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Download progress (isolated child view)

    // MARK: - Offline list

    private var offlineList: some View {
        LazyVStack(spacing: 0) {
            ForEach(offlineItems) { item in
                if item.localPath.isEmpty, let urlStr = item.sourceURL,
                   let url = URL(string: urlStr) {
                    NavigationLink(destination: WebReaderView(url: url)) {
                        OfflineItemRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteOfflineItem(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                } else {
                    NavigationLink(destination: offlineDestination(for: item)) {
                        OfflineItemRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteOfflineItem(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                Divider().padding(.leading, 56 + 12 + 12)
            }
        }
    }

    @ViewBuilder
    private func offlineDestination(for item: OfflineItem) -> some View {
        if let fileURL = OfflineFiles.shared.url(for: item.localPath) {
            switch item.fileType {
            case .pdf:       PDFReaderView(fileURL: fileURL)
            case .cbz, .cbr: CBZReaderView(fileURL: fileURL)
            case .epub:      EPUBReaderView(fileURL: fileURL)
            case .txt:       TXTReaderView(fileURL: fileURL)
            case .video:     VideoPlayerView(fileURL: fileURL)
            case .audio:     NASAudioView(trackName: item.title, trackPath: fileURL.path, fileURL: fileURL)
            default:         Text("不支持的格式")
            }
        } else { ContentUnavailableView("离线文件路径无效", systemImage: "doc.badge.ellipsis") }
    }

    private func deleteOfflineItem(_ item: OfflineItem) {
        // Delete local file if it exists
        if !item.localPath.isEmpty {
            OfflineFiles.shared.deleteFile(path: item.localPath)
        }
        modelContext.delete(item)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有内容", systemImage: "house")
        } description: {
            Text("去「收藏」查看已收藏内容，或在首页快速访问站点")
        }
        .padding(.top, 60)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .padding(.horizontal)
    }

    private func collapsibleHeader(_ title: String, collapsed: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                collapsed.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
                Spacer()
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnailView(_ item: ReadingHistory) -> some View {
        if item.thumbnailURL != nil {
            CachedThumbnail(url: item.thumbnailURL, placeholder: item.fileType.systemImage)
        } else if item.thumbnailData != nil {
            DataThumbnail(data: item.thumbnailData!, placeholder: item.fileType.systemImage)
        } else {
            Color(.secondarySystemBackground)
                .overlay {
                    Image(systemName: item.fileType.systemImage)
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private func destinationView(for item: ReadingHistory) -> some View {
        // NAS file: auto-reconnect and open
        if item.nasConfigID != nil, item.filePath != nil {
            NASAutoConnectView(historyItem: item)
        } else {
            localDestinationView(for: item)
        }
    }

    @ViewBuilder
    private func localDestinationView(for item: ReadingHistory) -> some View {
        switch item.fileType {
        case .audio:
            if let path = item.filePath, let fileURL = OfflineFiles.shared.historyURL(for: path) {
                NASAudioView(trackName: item.title, trackPath: fileURL.path, fileURL: fileURL)
            } else if let address = item.url, let url = URL(string: address) {
                NASAudioView(trackName: item.title, trackPath: address, fileURL: url)
            }
        case .web:
            if let s = item.url, let url = URL(string: s) {
                WebReaderView(url: url, historyItem: item)
            }
        case .article:
            if let address = item.url, let url = URL(string: address) {
                ArticleReaderView(item: ParsedItem(title: item.title, pageURL: url, thumbnail: item.thumbnailURL, duration: "", extra: ""), definitionID: item.definitionID, historyItem: item)
            }
        case .pdf:
            if let p = item.filePath, let fileURL = OfflineFiles.shared.historyURL(for: p) {
                PDFReaderView(fileURL: fileURL, historyItem: item)
            }
        case .cbz, .cbr:
            if let p = item.filePath, let fileURL = OfflineFiles.shared.historyURL(for: p) {
                CBZReaderView(fileURL: fileURL, historyItem: item)
            }
        case .epub:
            if let p = item.filePath, let fileURL = OfflineFiles.shared.historyURL(for: p) {
                EPUBReaderView(fileURL: fileURL, historyItem: item)
            }
        case .txt:
            if let p = item.filePath, let fileURL = OfflineFiles.shared.historyURL(for: p) {
                TXTReaderView(fileURL: fileURL, historyItem: item)
            }
        case .video:
            if let p = item.filePath, let fileURL = OfflineFiles.shared.historyURL(for: p) {
                // Local file → direct player
                VideoPlayerView(fileURL: fileURL, historyItem: item)
            } else if let s = item.url, let url = URL(string: s) {
                // Web video → extract stream and play natively
                VideoDetailView(item: ParsedItem(
                    title: item.title,
                    pageURL: url,
                    thumbnail: item.thumbnailURL,
                    duration: "",
                    extra: ""
                ), definitionID: item.definitionID)
            }
        case .comic:
            if let s = item.url, let url = URL(string: s) {
                ComicDetailView(item: ParsedItem(
                    title: item.title,
                    pageURL: url,
                    thumbnail: item.thumbnailURL,
                    duration: "",
                    extra: ""
                ), definitionID: item.definitionID)
            }
        default:
            Text("不支持的格式")
        }
    }
}

// MARK: - Site quick-access card

struct SiteQuickCard: View {
    let site: BookmarkSite

    /// Stable color derived from the site name.
    private var iconColor: Color {
        let colors: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .mint, .red]
        let hash = abs(site.name.hashValue)
        return colors[hash % colors.count]
    }

    /// First character of the site name for the icon.
    private var initial: String {
        String(site.name.prefix(1))
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(iconColor.gradient)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 4)

                Text(initial)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
            }

            Text(site.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 64)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Recent card

struct RecentCard: View {
    let item: ReadingHistory
    var cardSize: BentoCardSize = .small

    private var titleFont: Font {
        cardSize == .large
            ? .system(size: 15, weight: .semibold)
            : .system(size: 13, weight: .medium)
    }
    private var titleLines: Int { cardSize == .large ? 3 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailView
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(titleFont)
                    .lineLimit(titleLines)
                    .foregroundStyle(.primary)

                ProgressView(value: item.progress)
                    .tint(.accentColor)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if item.thumbnailURL != nil {
            CachedThumbnail(url: item.thumbnailURL, placeholder: item.fileType.systemImage)
        } else if item.thumbnailData != nil {
            DataThumbnail(data: item.thumbnailData!, placeholder: item.fileType.systemImage)
        } else {
            Color(.secondarySystemBackground)
                .overlay {
                    Image(systemName: item.fileType.systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - OfflineItemRow (kept here, shared with HomeView)

struct OfflineItemRow: View {
    let item: OfflineItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.fileType.systemImage)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.formattedSize).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Section header (shared)

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.title2.bold()).padding(.horizontal)
    }
}

// MARK: - Active downloads section (isolates DownloadManager observation)

/// Only this view re-evaluates when download progress changes — not the entire HomeView.
private struct ActiveDownloadsSection: View {
    let manager: DownloadManager
    var body: some View {
        let activeDownloads = manager.downloads.filter { $0.state != .completed }
        if !activeDownloads.isEmpty {
            Text("下载")
                .font(.title3.bold())
                .padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(activeDownloads) { dl in
                    DownloadProgressRow(download: dl, manager: manager)
                        .padding(.horizontal)
                    Divider().padding(.leading, 56 + 12 + 12)
                }
            }
        }
    }
}

// MARK: - Download progress row

struct DownloadProgressRow: View {
    let download: DownloadManager.Download
    var manager: DownloadManager = .shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: download.fileType.systemImage)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(download.title)
                    .font(.body)
                    .lineLimit(1)

                if case .failed(let msg) = download.state {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    ProgressView(value: download.progress)
                        .tint(.accentColor)
                }
            }

            Spacer()

            if case .failed = download.state {
                Button { manager.retry(id: download.id) } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
                .accessibilityLabel("重试下载")
            }
            Button { manager.cancel(id: download.id) } label: {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
            .accessibilityLabel("取消下载")

        }
        .padding(.vertical, 10)
    }
}

// MARK: - FileType systemImage

// MARK: - DataThumbnail (caches decoded UIImage in @State to avoid repeated decoding)

struct DataThumbnail: View {
    let data: Data
    var placeholder: String = "photo"
    @State private var image: UIImage?

    init(data: Data, placeholder: String = "photo") {
        self.data = data
        self.placeholder = placeholder
        _image = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
                    .overlay {
                        Image(systemName: placeholder)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: data) {
            let bytes = data
            let work = Task.detached(priority: .utility) { ImageDecoder.decode(bytes, sizing: .thumbnail(512)) }
            let loaded = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
