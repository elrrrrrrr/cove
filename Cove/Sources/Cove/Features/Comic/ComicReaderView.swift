import SwiftUI
import SwiftData
import WebKit

// MARK: - Chapter image data

struct ChapterImageData: Sendable {
    let imageURLs: [URL]
    let bookId: String
    let chapterId: String
    let chapterName: String
    let bookName: String
    let prevChapterURL: URL?
    let nextChapterURL: URL?
}

// MARK: - ChapterImageExtractor

@Observable
@MainActor
final class ChapterImageExtractor: NSObject {
    enum State {
        case loading, loaded(ChapterImageData), failed(String)
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
        self.definitionID = definitionID
        extractTask?.cancel()
        targetURL = url
        state = .loading
        webView.load(URLRequest(url: url))
    }

    func cancel() {
        extractTask?.cancel()
        extractTask = nil
        webView.stopLoading()
    }

    private func startExtraction() {
        extractTask?.cancel()
        extractTask = Task { await extract() }
    }

    private func extract() async {
        guard let target = targetURL,
              let rule = SiteParserRegistry.rule(for: target, role: "chapter", definitionID: definitionID) else {
            state = .failed("请先配置章节图片解析规则")
            return
        }
        do {
            if let request = rule.request {
                try await extractRequest(request, target: target)
                return
            }
            guard let extraction = rule.extract else { throw SiteDefinitionError.invalid("缺少章节提取规则") }
            for attempt in 0..<2 {
                try await Task.sleep(for: .seconds(attempt == 0 ? rule.load?.waitSeconds ?? 0 : 1.5))
                guard !Task.isCancelled else { return }
                guard let raw = try await WebScript.string(extraction.javascript, in: webView), let bytes = raw.data(using: .utf8) else { continue }
                let parsed = try JSONDecoder().decode(RawData.self, from: bytes)
                let urls = parsed.images.compactMap { URL(string: $0, relativeTo: target)?.absoluteURL }
                if !urls.isEmpty {
                    guard !Task.isCancelled else { return }
                    state = .loaded(makeChapterData(parsed, urls: urls))
                    return
                }
            }
            throw SiteDefinitionError.invalid("未找到漫画图片")
        } catch { if !Task.isCancelled { state = .failed("加载失败：\(error.localizedDescription)") } }
    }

    private func extractRequest(_ config: SiteTextRequest, target: URL) async throws {
        guard let capture = SitePortalResolver.captures(config.capturePattern, in: target.absoluteString).first,
              let url = URL(string: config.urlTemplate.replacingOccurrences(of: "{capture}", with: capture), relativeTo: target)?.absoluteURL else {
            throw SiteDefinitionError.invalid("无法从地址生成章节请求")
        }
        var request = URLRequest(url: url)
        request.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status),
              let text = String(data: bytes, encoding: .utf8) else { throw SiteDefinitionError.invalid("章节请求失败") }
        let urls = SitePortalResolver.captures(config.responsePattern, in: text)
            .filter { value in !(config.exclude ?? []).contains(where: { value.contains($0) }) }
            .compactMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        guard !Task.isCancelled else { return }
        guard !urls.isEmpty else { throw SiteDefinitionError.invalid("未找到图片，请检查响应规则") }
        state = .loaded(ChapterImageData(imageURLs: urls, bookId: capture, chapterId: capture,
            chapterName: "", bookName: "", prevChapterURL: nil, nextChapterURL: nil))
    }

    private struct RawData: Decodable {
        let images: [String]
        let bookId: String?
        let chapterId: String?
        let chapterName: String?
        let bookName: String?
        let prevChapter: String?
        let nextChapter: String?
    }

    private func makeChapterData(_ raw: RawData, urls: [URL]) -> ChapterImageData {
        ChapterImageData(
            imageURLs: urls,
            bookId: raw.bookId ?? "",
            chapterId: raw.chapterId ?? "",
            chapterName: raw.chapterName ?? "",
            bookName: raw.bookName ?? "",
            prevChapterURL: resolveURL(raw.prevChapter),
            nextChapterURL: resolveURL(raw.nextChapter)
        )
    }

    private func resolveURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        guard let base = targetURL else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }
}

extension ChapterImageExtractor: WKNavigationDelegate {
    nonisolated func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor in self.startExtraction() }
    }
    nonisolated func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
    nonisolated func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
}

// MARK: - ComicReaderView

struct ComicReaderView: View {
    let chapter: ComicChapter
    let allChapters: [ComicChapter]
    let bookTitle: String
    let bookURL: URL
    let definitionID: String?
    let coverURL: URL?
    var onChapterChange: ((ComicChapter) -> Void)?

    @State private var extractor = ChapterImageExtractor()
    @State private var currentChapter: ComicChapter
    @State private var showBars = true
    @State private var currentChapterIndex: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    init(chapter: ComicChapter, allChapters: [ComicChapter], bookTitle: String,
         bookURL: URL, coverURL: URL?, definitionID: String? = nil, onChapterChange: ((ComicChapter) -> Void)? = nil) {
        self.chapter = chapter
        self.allChapters = allChapters
        self.bookTitle = bookTitle
        self.bookURL = bookURL
        self.definitionID = definitionID
        self.coverURL = coverURL
        self.onChapterChange = onChapterChange
        _currentChapter = State(wrappedValue: chapter)
        _currentChapterIndex = State(wrappedValue: allChapters.firstIndex(where: { $0.id == chapter.id }) ?? 0)
    }

    private var hasPrev: Bool { currentChapterIndex > 0 }
    private var hasNext: Bool { currentChapterIndex < allChapters.count - 1 }
    @State private var showParsingWeb = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Hidden WebView
            HiddenWebView(webView: extractor.webView)
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)

            contentLayer

            // Top / bottom bars
            if showBars {
                barsOverlay
            }
        }
        .statusBarHidden(!showBars)
        .sheet(isPresented: $showParsingWeb) {
            ParsingWebViewSheet(webView: extractor.webView, request: URLRequest(url: currentChapter.chapterURL), status: inspectionStatus)
        }
        .task {
            extractor.load(url: currentChapter.chapterURL, definitionID: definitionID)
        }
        .onDisappear {
            extractor.cancel()
            saveProgress()
        }
    }

    private var inspectionStatus: String {
        switch extractor.state {
        case .loading: "加载章节中…"
        case .loaded: "章节解析已完成"
        case .failed(let message): "解析失败：\(message)"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentLayer: some View {
        switch extractor.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("加载中…")
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.subheadline)
                Button("查看原始网页", systemImage: "safari") { showParsingWeb = true }.buttonStyle(.bordered).tint(.white)
            }

        case .loaded(let data):
            imageScrollView(data)

        case .failed(let msg):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(msg)
                    .foregroundStyle(.white.opacity(0.8))
                Button("重试") {
                    extractor.load(url: currentChapter.chapterURL, definitionID: definitionID)
                }
                .buttonStyle(.borderedProminent)
                Button("查看原始网页", systemImage: "safari") { showParsingWeb = true }.buttonStyle(.bordered).tint(.white)
            }
        }
    }

    // MARK: - Image scroll

    private func imageScrollView(_ data: ChapterImageData) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("reader-top")

                    ForEach(Array(data.imageURLs.enumerated()), id: \.offset) { index, url in
                        ComicPageImage(url: url, index: index)
                    }

                    // Chapter end actions
                    chapterEndView
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showBars.toggle()
                }
            }
            .onChange(of: currentChapter.id) {
                withAnimation {
                    proxy.scrollTo("reader-top", anchor: .top)
                }
            }
        }
    }

    // MARK: - Chapter end

    private var chapterEndView: some View {
        VStack(spacing: 16) {
            Text(currentChapter.title)
                .font(.headline)
                .foregroundStyle(.white)

            HStack(spacing: 20) {
                if hasPrev {
                    Button {
                        navigateChapter(offset: -1)
                    } label: {
                        Label("上一章", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }

                if hasNext {
                    Button {
                        navigateChapter(offset: 1)
                    } label: {
                        Label("下一章", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Bars overlay

    private var barsOverlay: some View {
        VStack {
            // Top bar
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                VStack(alignment: .leading) {
                    Text(bookTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    Text(currentChapter.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .background(
                LinearGradient(colors: [.black.opacity(0.6), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )

            Spacer()

            // Bottom bar
            HStack(spacing: 24) {
                Button {
                    navigateChapter(offset: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .disabled(!hasPrev)

                Text("\(currentChapterIndex + 1) / \(allChapters.count)")
                    .font(.subheadline.monospacedDigit())

                Button {
                    navigateChapter(offset: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                }
                .disabled(!hasNext)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
    }

    // MARK: - Chapter navigation

    private func navigateChapter(offset: Int) {
        let newIndex = currentChapterIndex + offset
        guard newIndex >= 0 && newIndex < allChapters.count else { return }
        saveProgress()
        currentChapterIndex = newIndex
        currentChapter = allChapters[newIndex]
        onChapterChange?(currentChapter)
        extractor.load(url: currentChapter.chapterURL, definitionID: definitionID)
    }

    // MARK: - Progress

    private func saveProgress() {
        let urlString = bookURL.absoluteString
        let progress = allChapters.isEmpty ? 0 : Double(currentChapterIndex) / Double(allChapters.count)
        let comicType = FileType.comic
        let descriptor = FetchDescriptor<ReadingHistory>(
            predicate: #Predicate { $0.url == urlString && $0.fileType == comicType }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.definitionID = definitionID
            existing.progress = progress
            existing.lastReadAt = Date()
            existing.filePath = currentChapter.id  // store last-read chapter ID
        } else {
            let entry = ReadingHistory(
                title: bookTitle,
                url: urlString,
                filePath: currentChapter.id,
                fileType: .comic,
                progress: progress,
                thumbnailURLString: coverURL?.absoluteString
            )
            entry.definitionID = definitionID
            modelContext.insert(entry)
        }
    }
}

// MARK: - Comic page image

private struct ComicPageImage: View {
    let url: URL
    let index: Int

    @Environment(\.displayScale) private var scale
    @State private var pixels = 1024
    private let source: ThumbnailRequest
    private var request: ThumbnailRequest { source.resized(.page(width: pixels)) }
    @State private var image: UIImage?
    @State private var failed = false
    @State private var isVisible = true

    init(url: URL, index: Int) {
        self.url = url
        self.index = index
        source = ThumbnailRequest(url: url, sizing: .page(width: 1024))
        _image = State(initialValue: ImageMemoryCache.shared.image(for: source))
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
                        .foregroundStyle(.white.opacity(0.5))
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
            } else {
                ProgressView()
                    .tint(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 400)
            }
        }
        .onGeometryChange(for: Int.self) { [scale] proxy in ImageSizing.pixels(points: proxy.size.width, scale: scale) } action: { pixels = $0 }
        .task(id: request) {
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
            isVisible = true
            // Re-load from L0 cache if image was released while off-screen
            if image == nil, !failed {
                image = ImageMemoryCache.shared.image(for: request)
            }
        }
        .onDisappear {
            isVisible = false
            // Delay release to avoid re-load on quick scroll back;
            // L0/L1/L2 cache retains the data so re-loading is nearly instant.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !isVisible else { return }
                image = nil
            }
        }
    }
}
