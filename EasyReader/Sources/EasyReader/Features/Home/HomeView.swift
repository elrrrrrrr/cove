import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \ReadingHistory.lastReadAt, order: .reverse, animation: .default)
    private var history: [ReadingHistory]

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

    /// Deduplicated by URL/filePath AND title (content-based), newest first.
    /// Title dedup merges e.g. multiple comic chapters into a single entry.
    private var recentHistory: [ReadingHistory] {
        let maxItems = hSizeClass == .regular ? 12 : 5
        var seenKeys   = Set<String>()
        var seenTitles = Set<String>()
        var result: [ReadingHistory] = []
        for item in history {
            let key = item.url ?? item.filePath ?? item.id.uuidString
            guard seenKeys.insert(key).inserted else { continue }
            guard seenTitles.insert(item.displayTitle).inserted else { continue }
            result.append(item)
            if result.count == maxItems { break }
        }
        return result
    }

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
                    if let latest = history.first {
                        sectionHeader("继续阅读")
                        continueReadingCard(latest)
                    }

                    // ── 最近阅读 ──────────────────────────────────────
                    if !recentHistory.isEmpty {
                        collapsibleHeader("最近阅读", collapsed: $recentCollapsed)
                        if !recentCollapsed { recentRow }
                    }

                    // ── 下载中 ──────────────────────────────────────
                    ActiveDownloadsSection()

                    // ── 稍后再看 ──────────────────────────────────────
                    if !offlineItems.isEmpty {
                        collapsibleHeader("稍后再看", collapsed: $offlineCollapsed)
                        if !offlineCollapsed { offlineList }
                    }

                    // ── 空状态 ────────────────────────────────────────
                    if sites.isEmpty && history.isEmpty {
                        emptyState
                    }
                }
                .padding(.vertical)
            }
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
        BentoVideoGrid(items: recentHistory, columns: columns) { item, cardSize in
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
        let fileURL = URL(fileURLWithPath: item.localPath)
        switch item.fileType {
        case .pdf:       PDFReaderView(fileURL: fileURL)
        case .cbz, .cbr: CBZReaderView(fileURL: fileURL)
        case .epub:      EPUBReaderView(fileURL: fileURL)
        case .txt:       TXTReaderView(fileURL: fileURL)
        case .video:     VideoPlayerView(fileURL: fileURL)
        default:         Text("不支持的格式")
        }
    }

    private func deleteOfflineItem(_ item: OfflineItem) {
        // Delete local file if it exists
        if !item.localPath.isEmpty {
            try? FileManager.default.removeItem(atPath: item.localPath)
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
        if item.nasConfigID != nil, let filePath = item.filePath {
            NASAutoConnectView(historyItem: item)
        } else {
            localDestinationView(for: item)
        }
    }

    @ViewBuilder
    private func localDestinationView(for item: ReadingHistory) -> some View {
        switch item.fileType {
        case .web:
            if let s = item.url, let url = URL(string: s) {
                WebReaderView(url: url)
            }
        case .pdf:
            if let p = item.filePath {
                PDFReaderView(fileURL: URL(fileURLWithPath: p))
            }
        case .cbz, .cbr:
            if let p = item.filePath {
                CBZReaderView(fileURL: URL(fileURLWithPath: p))
            }
        case .epub:
            if let p = item.filePath {
                EPUBReaderView(fileURL: URL(fileURLWithPath: p))
            }
        case .txt:
            if let p = item.filePath {
                TXTReaderView(fileURL: URL(fileURLWithPath: p))
            }
        case .video:
            if let p = item.filePath {
                // Local file → direct player
                VideoPlayerView(fileURL: URL(fileURLWithPath: p))
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
    var body: some View {
        let activeDownloads = DownloadManager.shared.downloads.filter { !$0.state.isTerminal }
        if !activeDownloads.isEmpty {
            Text("下载中")
                .font(.title3.bold())
                .padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(activeDownloads) { dl in
                    DownloadProgressRow(download: dl)
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
                Button {
                    DownloadManager.shared.retry(id: download.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    DownloadManager.shared.cancel(id: download.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
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
        _image = State(initialValue: UIImage(data: data))
    }

    var body: some View {
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
}
