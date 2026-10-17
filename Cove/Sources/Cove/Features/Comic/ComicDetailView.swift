import SwiftUI
import SwiftData
import WebKit

// MARK: - Data types

struct ComicChapter: Identifiable, Sendable {
    let id: String          // chapter ID from URL path
    let title: String       // e.g. "第1話"
    let chapterURL: URL
}

struct ComicMeta: Sendable {
    let title: String
    let author: String
    let status: String
    let tags: [String]
    let description: String
    let coverURL: URL?
    let chapters: [ComicChapter]
}

// MARK: - ComicDetailLoader

@Observable
@MainActor
final class ComicDetailLoader: NSObject {
    enum State {
        case loading, loaded(ComicMeta), failed(String)
    }
    var state: State = .loading
    let webView: WKWebView

    private var targetURL: URL?
    private var definitionID: String?
    private var extractTask: Task<Void, Never>?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = SiteWebSession.dataStore
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        self.webView = wv
        super.init()
        wv.navigationDelegate = self
    }

    func load(url: URL, definitionID: String? = nil) {
        extractTask?.cancel()
        self.definitionID = definitionID
        targetURL = url
        state = .loading
        // Try URLSession fast path first (avoids cookie/anti-bot issues)
        extractTask = Task { await fetchAndLoad(url: url) }
    }

    func cancel() {
        extractTask?.cancel()
        webView.stopLoading()
    }

    /// URLSession fetch → strip scripts → loadHTMLString.
    /// Shares cookies via HTTPCookieStorage and avoids WKWebView navigation issues.
    private func fetchAndLoad(url: URL) async {
        if SiteParserRegistry.rule(for: url, role: "comic", definitionID: definitionID)?.load?.mode == "webView" {
            webView.load(URLRequest(url: url))
            return
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
                // Fallback to direct WebView navigation
                webView.load(URLRequest(url: url))
                return
            }
            let stripped = Self.stripResourceTags(html)
            webView.loadHTMLString(stripped, baseURL: url)
        } catch {
            webView.load(URLRequest(url: url))
        }
    }

    private static func stripResourceTags(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(
            of: #"<script\b[^>]*>[\s\S]*?</script>"#,
            with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"<script\b[^/]*/>"#,
            with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"<link\b[^>]*>"#,
            with: "", options: .regularExpression)
        return result
    }

    private func extract() {
        extractTask?.cancel()
        extractTask = Task {
            guard let target = targetURL,
                  let rule = SiteParserRegistry.rule(for: target, role: "comic", definitionID: definitionID),
                  let extraction = rule.extract else {
                state = .failed("请先配置漫画详情解析规则")
                return
            }
            try? await Task.sleep(for: .seconds(rule.load?.waitSeconds ?? 0))
            guard !Task.isCancelled else { return }
            do {
                guard let raw = try await WebScript.string(extraction.javascript, in: webView),
                      let bytes = raw.data(using: .utf8) else { throw SiteDefinitionError.invalid("解析结果为空") }
                let meta = try JSONDecoder().decode(RawMeta.self, from: bytes)
                let chapters = meta.chapters.compactMap { chapter -> ComicChapter? in
                    guard let url = URL(string: chapter.url, relativeTo: target)?.absoluteURL else { return nil }
                    return ComicChapter(id: chapter.id ?? url.absoluteString, title: chapter.title ?? "开始阅读", chapterURL: url)
                }
                guard !Task.isCancelled else { return }
                guard !chapters.isEmpty else { throw SiteDefinitionError.invalid("未找到章节，请检查解析规则") }
                state = .loaded(ComicMeta(title: meta.title ?? "", author: meta.author ?? "", status: meta.status ?? "",
                    tags: meta.tags ?? [], description: meta.desc ?? "",
                    coverURL: meta.cover.flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: target)?.absoluteURL }, chapters: chapters))
            } catch { if !Task.isCancelled { state = .failed("提取失败：\(error.localizedDescription)") } }
        }
    }

    private struct RawMeta: Decodable {
        let title: String?
        let author: String?
        let status: String?
        let tags: [String]?
        let desc: String?
        let cover: String?
        let chapters: [RawChapter]
    }
    private struct RawChapter: Decodable {
        let id: String?
        let title: String?
        let url: String
    }
}

extension ComicDetailLoader: WKNavigationDelegate {
    nonisolated func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor in self.extract() }
    }
    nonisolated func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
}

// MARK: - ComicDetailView

struct ComicDetailView: View {
    let item: ParsedItem
    var definitionID: String? = nil

    @State private var loader = ComicDetailLoader()
    @State private var showReaderFor: ComicChapter?
    @State private var lastReadChapterId: String?
    @State private var showParsingWeb = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            // Hidden WebView for extraction
            HiddenWebView(webView: loader.webView)
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)

            contentLayer
        }
        .appSurface()
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("查看原始网页", systemImage: "safari") { showParsingWeb = true }
            }
        }
        .sheet(isPresented: $showParsingWeb) {
            ParsingWebViewSheet(webView: loader.webView, request: URLRequest(url: item.pageURL), status: inspectionStatus)
        }
        .task {
            loader.load(url: item.pageURL, definitionID: definitionID)
            // Find last-read chapter using a targeted query instead of loading all history
            let urlString = item.pageURL.absoluteString
            let comicType = FileType.comic
            let descriptor = FetchDescriptor<ReadingHistory>(
                predicate: #Predicate { $0.url == urlString && $0.fileType == comicType }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                lastReadChapterId = existing.filePath
            }
        }
        .onDisappear { loader.cancel() }
        .fullScreenCover(item: $showReaderFor) { chapter in
            comicReaderDestination(chapter)
        }
    }

    private var inspectionStatus: String {
        switch loader.state {
        case .loading: "加载漫画详情中…"
        case .loaded: "漫画详情解析已完成"
        case .failed(let message): "解析失败：\(message)"
        }
    }

    @ViewBuilder
    private var contentLayer: some View {
        switch loader.state {
        case .loading:
            loadingView
        case .loaded(let meta):
            detailContent(meta)
        case .failed(let msg):
            ContentUnavailableView {
                Label("加载失败", systemImage: "wifi.slash")
            } description: {
                Text(msg)
            } actions: {
                Button("重试") { loader.load(url: item.pageURL, definitionID: definitionID) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Show cover placeholder from parsed item thumbnail
                if item.thumbnail != nil {
                    CachedThumbnail(url: item.thumbnail, placeholder: "photo.on.rectangle.angled")
                        .aspectRatio(2/3, contentMode: .fit)
                        .frame(maxWidth: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .aspectRatio(2/3, contentMode: .fit)
                        .frame(maxWidth: 200)
                }
                Text(item.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                ProgressView("加载中…")
                Button("查看原始网页", systemImage: "safari") { showParsingWeb = true }.buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Detail content

    private func detailContent(_ meta: ComicMeta) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ── Cover + info header ──
                HStack(alignment: .top, spacing: 16) {
                    // Cover
                    Group {
                        if let coverURL = meta.coverURL {
                            CachedThumbnail(url: coverURL, placeholder: "photo.on.rectangle.angled")
                        } else if item.thumbnail != nil {
                            CachedThumbnail(url: item.thumbnail, placeholder: "photo.on.rectangle.angled")
                        } else {
                            Color(.secondarySystemBackground)
                                .overlay {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.title2).foregroundStyle(.tertiary)
                                }
                        }
                    }
                    .aspectRatio(2/3, contentMode: .fit)
                    .frame(width: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                    // Info
                    VStack(alignment: .leading, spacing: 8) {
                        Text(meta.title)
                            .font(.title3.bold())
                            .lineLimit(3)

                        if !meta.author.isEmpty {
                            Label(meta.author, systemImage: "person")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !meta.status.isEmpty {
                            Label(meta.status, systemImage: meta.status.contains("完") ? "checkmark.circle" : "clock")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Tags
                        if !meta.tags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(meta.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)

                // ── Description ──
                if !meta.description.isEmpty {
                    Text(meta.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(.horizontal)
                }

                // ── Action button ──
                actionButton(meta)

                Divider().padding(.horizontal)

                // ── Chapter list ──
                chapterList(meta)
            }
            .padding(.vertical)
        }
    }

    // MARK: - Action button

    @ViewBuilder
    private func actionButton(_ meta: ComicMeta) -> some View {
        let resumeChapter = lastReadChapterId.flatMap { cid in
            meta.chapters.first(where: { $0.id == cid })
        }
        Button {
            showReaderFor = resumeChapter ?? meta.chapters.first
        } label: {
            HStack {
                Image(systemName: resumeChapter != nil ? "book" : "play.fill")
                Text(resumeChapter != nil ? "继续阅读 \(resumeChapter!.title)" : "开始阅读")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
    }

    // MARK: - Chapter list

    private func chapterList(_ meta: ComicMeta) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("章节列表")
                    .font(.headline)
                Spacer()
                Text("\(meta.chapters.count) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            ForEach(meta.chapters) { chapter in
                chapterRow(chapter)
            }
        }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: ComicChapter) -> some View {
        let isLastRead = chapter.id == (lastReadChapterId ?? "")
        Button {
            showReaderFor = chapter
        } label: {
            HStack {
                if isLastRead {
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(.accentColor)
                        .font(.caption)
                }
                Text(chapter.title)
                    .font(.subheadline)
                    .foregroundColor(isLastRead ? .accentColor : .primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider().padding(.leading)
    }

    // MARK: - Reader destination

    @ViewBuilder
    private func comicReaderDestination(_ chapter: ComicChapter) -> some View {
        if case .loaded(let meta) = loader.state {
            ComicReaderView(
                chapter: chapter,
                allChapters: meta.chapters,
                bookTitle: meta.title,
                bookURL: item.pageURL,
                coverURL: meta.coverURL ?? item.thumbnail,
                definitionID: definitionID ?? SiteParserRegistry.definition(for: item.pageURL)?.id,
                onChapterChange: { newChapter in
                    lastReadChapterId = newChapter.id
                }
            )
        }
    }
}

// MARK: - FlowLayout (simple horizontal wrap)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - ComicChapter conformance for fullScreenCover(item:)

extension ComicChapter: Hashable {
    static func == (lhs: ComicChapter, rhs: ComicChapter) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
