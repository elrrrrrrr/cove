import SwiftUI
import SwiftData
import WebKit

// MARK: - Chapter image data

struct ChapterImageData: Sendable {
    let imageURLs: [URL]
}

// MARK: - ChapterImageExtractor

@Observable
@MainActor
final class ChapterImageExtractor {
    enum State {
        case loading, loaded(ChapterImageData), failed(String)
    }
    var state: State = .loading
    let webView = WebScript.makeWebView()

    private var navBridge: WebNavigationBridge?
    private var targetURL: URL?
    private var definitionID: String?
    private var extractTask: Task<Void, Never>?

    init() {
        navBridge = WebNavigationBridge.attach(
            to: webView,
            onFinish: { [weak self] _ in
                guard let self, case .loading = state else { return }
                startExtraction()
            },
            onFail: { [weak self] _, error in
                guard let self, case .loading = state else { return }
                state = .failed(error.localizedDescription)
            }
        )
    }

    func load(url: URL, definitionID: String? = nil) {
        self.definitionID = definitionID
        extractTask?.cancel()
        targetURL = url
        state = .loading
        let headers = SiteParserRegistry.rule(for: url, role: "chapter", definitionID: definitionID)?.load?.headers ?? [:]
        webView.load(WebScript.makeRequest(url: url, headers: headers))
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
                try await extractRequest(request, target: target, headers: rule.load?.headers ?? [:])
                return
            }
            guard let extraction = rule.extract else { throw SiteDefinitionError.invalid("缺少章节提取规则") }
            for attempt in 0..<2 {
                try await Task.sleep(for: .seconds(attempt == 0 ? rule.load?.waitSeconds ?? 0 : 1.5))
                guard !Task.isCancelled else { return }
                guard let raw = try await WebScript.boundedString(extraction.javascript, in: webView),
                      let bytes = raw.data(using: .utf8) else { continue }
                let parsed = try JSONDecoder().decode(RawData.self, from: bytes)
                let urls = parsed.images.compactMap { WebScript.resolveURL($0, relativeTo: target, allowData: true) }
                if !urls.isEmpty {
                    guard !Task.isCancelled else { return }
                    state = .loaded(ChapterImageData(imageURLs: urls))
                    return
                }
            }
            throw SiteDefinitionError.invalid("未找到漫画图片")
        } catch { if !Task.isCancelled { state = .failed("加载失败：\(error.localizedDescription)") } }
    }

    private func extractRequest(_ config: SiteTextRequest, target: URL, headers: [String: String]) async throws {
        guard let capture = SitePortalResolver.captures(config.capturePattern, in: target.absoluteString).first,
              let url = WebScript.resolveURL(config.urlTemplate.replacingOccurrences(of: "{capture}", with: capture), relativeTo: target) else {
            throw SiteDefinitionError.invalid("无法从地址生成章节请求")
        }
        let request = WebScript.makeRequest(url: url, headers: headers, userAgent: webView.customUserAgent, timeout: 15)
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status),
              let text = String(data: bytes, encoding: .utf8) else { throw SiteDefinitionError.invalid("章节请求失败") }
        let urls = SitePortalResolver.captures(config.responsePattern, in: text)
            .filter { value in !(config.exclude ?? []).contains(where: { value.contains($0) }) }
            .compactMap { WebScript.resolveURL($0, relativeTo: url, allowData: true) }
        guard !Task.isCancelled else { return }
        guard !urls.isEmpty else { throw SiteDefinitionError.invalid("未找到图片，请检查响应规则") }
        state = .loaded(ChapterImageData(imageURLs: urls))
    }

    private struct RawData: Decodable {
        let images: [String]
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
            ParsingWebViewHost(webView: extractor.webView, accessibilityHidden: true)
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

                    ForEach(Array(data.imageURLs.enumerated()), id: \.offset) { _, url in
                        PageImageView(
                            url: url,
                            referer: currentChapter.chapterURL,
                            definitionID: definitionID,
                            placeholderHeight: 400,
                            spinnerTint: .white.opacity(0.5),
                            placeholderBackground: nil,
                            failureColor: .white.opacity(0.5)
                        )
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

                Text(allChapters.isEmpty ? "0 / 0" : "\(currentChapterIndex + 1) / \(allChapters.count)")
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
        let progress = allChapters.isEmpty ? 0 : Double(currentChapterIndex) / Double(allChapters.count)
        ReadingHistory.recordProgress(
            in: modelContext,
            historyItem: nil,
            title: bookTitle,
            url: bookURL.absoluteString,
            filePath: currentChapter.id,
            fileType: .comic,
            progress: progress,
            thumbnailURLString: coverURL?.absoluteString,
            definitionID: definitionID,
            updateFilePath: true,
            updateMetadata: true
        )
    }
}
