import SwiftUI
import SwiftData
import os

struct ArticleReaderView: View {
    let item: ParsedItem
    var definitionID: String?
    var historyItem: ReadingHistory?
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @AppStorage("readerFontSize") private var fontSize = 17.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 8.0
    @State private var loader = ArticleLoader()
    @State private var history: ReadingHistory?
    @State private var progress = 0.0
    @State private var restored = false
    @State private var restoration: Task<Void, Never>?
    @State private var metrics = ArticleScroll(maximum: 0, progress: 0, ready: false)
    @State private var position = ScrollPosition(edge: .top)
    @State private var favorited = false
    @State private var showOriginal = false
    @State private var link: ArticleLink?
    @State private var error: String?
    @State private var width: CGFloat = 320

    var body: some View {
        ZStack {
            switch loader.state {
            case .idle, .loading:
                VStack(spacing: 18) {
                    ProgressView()
                    Text(item.title).font(.headline).multilineTextAlignment(.center)
                    Button("查看原始网页") { showOriginal = true }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("暂时无法提取正文", systemImage: "doc.text.magnifyingglass")
                } description: { Text(message) } actions: {
                    Button("重试") { reload() }
                    Button("查看原始网页") { showOriginal = true }
                }
            case .loaded(let document):
                reading(document)
            }
        }
        .foregroundStyle(theme.textColor)
        .background(theme.backgroundColor.ignoresSafeArea())
        .background {
            if loader.request != nil {
                GeometryReader { geometry in
                    HiddenWebView(webView: loader.webView)
                        .frame(width: max(320, geometry.size.width), height: max(600, geometry.size.height))
                        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .navigationTitle("图文阅读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(favorited ? "取消收藏" : "收藏", systemImage: favorited ? "heart.fill" : "heart") {
                    do { favorited = try ArticleReadingStore.toggleFavorite(item: item, title: title, definitionID: definitionID, document: document, in: context) }
                    catch { self.error = error.localizedDescription }
                }.foregroundColor(.accentColor).accessibilityIdentifier("article-favorite")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("查看原始网页", systemImage: "safari") { showOriginal = true }
                    if case .loaded(let document) = loader.state, let comments = document.commentsURL {
                        Button("查看评论", systemImage: "text.bubble") { link = ArticleLink(url: comments) }
                    }
                    Button("增大字号", systemImage: "textformat.size.larger") { fontSize = min(32, fontSize + 1) }
                    Button("减小字号", systemImage: "textformat.size.smaller") { fontSize = max(12, fontSize - 1) }
                    Button("重新解析", systemImage: "arrow.clockwise") { persist(); reload() }
                    ShareLink(item: item.pageURL)
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("图文阅读选项")
            }
        }
        .sheet(isPresented: $showOriginal) {
            ParsingWebViewSheet(webView: loader.webView, request: loader.request ?? URLRequest(url: item.pageURL),
                                status: "图文解析页面")
        }
        .sheet(item: $link) { target in
            NavigationStack { WebReaderView(url: target.url) }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard ArticleDocument.address(url.absoluteString, base: item.pageURL) != nil else { return .discarded }
            link = ArticleLink(url: url); return .handled
        })
        .task(id: item.pageURL) {
            do {
                if let historyItem { history = historyItem }
                else { history = try ArticleReadingStore.history(for: item.pageURL, in: context) }
                favorited = try ArticleReadingStore.favorite(for: item.pageURL, in: context) != nil
            } catch { self.error = error.localizedDescription }
            if case .idle = loader.state {
                if let document = item.article { loader.display(document) }
                else if let data = try? ArticleReadingStore.favorite(for: item.pageURL, in: context)?.articleSnapshot,
                        let document = try? ArticleDocument.decode(data, base: item.pageURL, fallbackTitle: item.title) { loader.display(document) }
                else { reload() }
            }
        }
        .onChange(of: loader.state) { _, state in
            guard case .loaded(let document) = state else { return }
            do {
                if let favorite = try ArticleReadingStore.favorite(for: item.pageURL, in: context) {
                    favorite.articleSnapshot = try document.snapshotData()
                    try context.save()
                }
            } catch { self.error = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            do { favorited = try ArticleReadingStore.favorite(for: item.pageURL, in: context) != nil }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { persist() } }
        .onDisappear { persist(); restoration?.cancel(); restoration = nil; loader.cancel() }
        .alert("阅读记录操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var document: ArticleDocument? {
        if case .loaded(let document) = loader.state { return document }; return nil
    }
    private var title: String {
        if case .loaded(let document) = loader.state { return document.title }
        return item.title
    }
    private func reload() {
        restoration?.cancel(); restoration = nil; restored = false
        loader.load(url: item.pageURL, title: item.title, definitionID: definitionID)
    }
    private func persist() {
        guard case .loaded = loader.state, restored else { return }
        do {
            history = try ArticleReadingStore.save(item: item, title: title, definitionID: definitionID,
                progress: progress, existing: history, in: context)
        } catch {
            self.error = error.localizedDescription
            Logger(subsystem: "Cove", category: "Article").error("阅读进度保存失败：\(error.localizedDescription, privacy: .private)")
        }
    }

    private func reading(_ document: ArticleDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                let firstParagraph = document.blocks.first { $0.kind == .paragraph }.map { String($0.text.characters) } ?? ""
                if !firstParagraph.hasPrefix(document.title) {
                    Text(document.title).font(.system(size: fontSize + 10, weight: .bold))
                        .accessibilityIdentifier("article-title")
                }
                let date = (try? Date(document.publishedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                    ?? (try? Date(document.publishedAt, strategy: .iso8601))
                let published = date?.formatted(date: .abbreviated, time: .shortened) ?? document.publishedAt
                let metadata = [document.author, published].filter { !$0.isEmpty }.joined(separator: " · ")
                if !metadata.isEmpty { Text(metadata).font(.subheadline).foregroundStyle(.secondary) }
                if let source = document.sourceURL, source != item.pageURL {
                    NavigationLink {
                        ArticleReaderView(item: ParsedItem(title: document.title, pageURL: source, thumbnail: item.thumbnail, duration: "", extra: document.author), definitionID: definitionID)
                    } label: { Label("阅读原文", systemImage: "doc.text") }.foregroundColor(.accentColor)
                }
                ForEach(document.blocks) { block in blockView(block).accessibilityIdentifier("article-" + block.id) }
            }
            .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            .padding(22).textSelection(.enabled)
        }
        .accessibilityIdentifier("article-content")
        .onGeometryChange(for: CGFloat.self) { max(180, min(760, $0.size.width - 44)) } action: { width = $0 }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ArticleScroll.self) { geometry in
            let maximum = max(0, geometry.contentSize.height - geometry.containerSize.height)
            let offset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            return ArticleScroll(maximum: maximum, progress: maximum > 0 ? min(1, Double(offset / maximum)) : 1, ready: geometry.contentSize.height > 0 && geometry.containerSize.height > 0)
        } action: { _, value in
            metrics = value
            guard value.ready else { return }
            if !restored {
                guard restoration == nil else { return }
                restoration = Task { @MainActor in
                    // Let the scroll view finish its first layout before applying a saved offset.
                    await Task.yield()
                    guard !Task.isCancelled, metrics.ready else { return }
                    let saved = history?.progress ?? (metrics.maximum == 0 ? 1 : 0)
                    progress = saved.isFinite ? min(1, max(0, saved)) : 0
                    if metrics.maximum > 0, progress > 0 { position.scrollTo(y: metrics.maximum * progress) }
                    restored = true; restoration = nil
                }
            } else { progress = value.progress }
        }
    }

    @ViewBuilder private func blockView(_ block: ArticleBlock) -> some View {
        switch block.kind {
        case .image:
            if let url = block.url {
                VStack(alignment: .leading, spacing: 6) {
                    ArticleImage(url: url, referer: item.pageURL, definitionID: definitionID, width: width, aspectRatio: block.aspectRatio)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(block.alt.isEmpty ? "文章图片" : block.alt)
                    if !block.alt.isEmpty { Text(block.alt).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case .link:
            if let url = block.url { Link(destination: url) { Text(block.text) }.foregroundColor(.accentColor) }
        case .heading:
            Text(block.text).font(.system(size: fontSize + (block.level <= 2 ? 6 : 2), weight: .semibold))
        case .quote:
            Text(block.text).font(.system(size: fontSize)).lineSpacing(lineSpacing)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .code:
            ScrollView(.horizontal) { Text(block.text).font(.system(size: fontSize - 2, design: .monospaced)).padding(14) }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .paragraph:
            Text(block.text).font(.system(size: fontSize)).lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ArticleScroll: Equatable { let maximum: CGFloat; let progress: Double; let ready: Bool }
private struct ArticleLink: Identifiable { let url: URL; var id: URL { url } }
