import SwiftUI
import SwiftData
import PDFKit
@preconcurrency import WebKit
import CryptoKit

// MARK: - Unified Document Reader (Article / TXT / EPUB / PDF)

struct DocumentReaderView: View {
    enum Source {
        case article(item: ParsedItem, definitionID: String?, siteName: String, history: ReadingHistory?)
        case txt(url: URL, history: ReadingHistory?)
        case pdf(url: URL, history: ReadingHistory?)
        case epub(url: URL, history: ReadingHistory?)
    }

    let source: Source

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark

    @State private var session = WebSession()
    @State private var articleDoc: ArticleDocument?
    @State private var txtText = ""
    @State private var txtChapters: [(title: String, fraction: Double)] = []
    @State private var epubChapters: [EPUBChapter] = []
    @State private var epubIndex = 0
    @State private var pdfPage = 1
    @State private var pdfTotal = 0
    @State private var pdfJump: Int?
    @State private var scrollPos = ScrollPosition(edge: .top)
    @State private var scrollFraction: Double = 0
    @State private var isLoading = true
    @State private var error: String?
    @State private var showBars = true
    @State private var showTOC = false
    @State private var showInspect = false

    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            if isLoading {
                ProgressView("加载中…")
            } else if let error {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "doc.text.magnifyingglass")
                } description: { Text(error) } actions: {
                    Button("重试") { Task { await load() } }.buttonStyle(.borderedProminent)
                    if case .article = source { Button("查看原始网页") { showInspect = true } }
                }
            } else {
                readerBody
            }

            if showBars && !isLoading && error == nil {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").frame(width: 36, height: 36).glassEffect(.regular, in: Circle())
                        }
                        Spacer()
                        Text(navTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: Capsule())
                        Spacer()
                        if hasTOC {
                            Button { showTOC = true } label: {
                                Image(systemName: "list.bullet").frame(width: 36, height: 36).glassEffect(.regular, in: Circle())
                            }
                        }
                    }.padding(.horizontal).padding(.top, 8)
                    Spacer()
                    floatingBottomBar
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
        .onDisappear { saveProgress(); session.cancel() }
        .sheet(isPresented: $showTOC) { tocSheet }
        .sheet(isPresented: $showInspect) {
            if let req = session.originalRequest { ParsingWebViewSheet(webView: session.webView, request: req) }
        }
    }

    private var navTitle: String {
        switch source {
        case .article(let item, _, _, _): articleDoc?.title ?? item.title
        case .txt(let url, _), .pdf(let url, _), .epub(let url, _): url.deletingPathExtension().lastPathComponent
        }
    }

    private var hasTOC: Bool {
        switch source {
        case .txt: !txtChapters.isEmpty
        case .epub: !epubChapters.isEmpty
        default: false
        }
    }

    @ViewBuilder
    private var readerBody: some View {
        switch source {
        case .article(let item, let defID, _, _):
            if let doc = articleDoc {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(doc.title).font(.system(size: fontSize + 8, weight: .bold))
                        let meta = [doc.author, doc.publishedAt].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !meta.isEmpty { Text(meta).font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(doc.blocks) { block in
                            articleBlockView(block, pageURL: item.pageURL, defID: defID)
                        }
                    }
                    .frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
                    .padding(.horizontal, 20).padding(.vertical, 68).textSelection(.enabled)
                }
                .scrollPosition($scrollPos)
                .onScrollGeometryChange(for: Double.self) { g in
                    let maxY = max(1, g.contentSize.height - g.containerSize.height)
                    return min(max(Double(g.contentOffset.y / maxY), 0), 1)
                } action: { _, f in scrollFraction = f }
                .foregroundStyle(theme.textColor)
                .onTapGesture { withAnimation { showBars.toggle() } }
            }

        case .txt:
            ScrollView {
                Text(txtText)
                    .font(.system(size: fontSize)).lineSpacing(7)
                    .foregroundStyle(theme.textColor)
                    .frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
                    .padding(.horizontal, 20).padding(.vertical, 68)
            }
            .scrollPosition($scrollPos)
            .onScrollGeometryChange(for: Double.self) { g in
                let maxY = max(1, g.contentSize.height - g.containerSize.height)
                return min(max(Double(g.contentOffset.y / maxY), 0), 1)
            } action: { _, f in scrollFraction = f }
            .onTapGesture { withAnimation { showBars.toggle() } }

        case .epub:
            if epubChapters.indices.contains(epubIndex) {
                EPUBWebView(chapter: epubChapters[epubIndex], fontSize: fontSize, theme: theme) {
                    withAnimation { showBars.toggle() }
                }
                .ignoresSafeArea()
            }

        case .pdf(let url, let history):
            PDFKitView(url: url, initialProgress: history?.progress, jumpToPage: $pdfJump) { cur, tot in
                pdfPage = cur; pdfTotal = tot
            } onFail: { error = "无法打开 PDF" } onTap: { withAnimation { showBars.toggle() } }
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func articleBlockView(_ block: ArticleBlock, pageURL: URL, defID: String?) -> some View {
        switch block.kind {
        case .image:
            CoveImage(url: block.url, referer: pageURL, definitionID: defID, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        case .heading:
            Text(block.text).font(.system(size: fontSize + 4, weight: .semibold))
        case .quote:
            Text(block.text).font(.system(size: fontSize)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        case .code:
            ScrollView(.horizontal) { Text(block.text).font(.system(size: fontSize - 2, design: .monospaced)).padding(12) }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        default:
            Text(block.text).font(.system(size: fontSize)).lineSpacing(7)
        }
    }

    @ViewBuilder
    private var floatingBottomBar: some View {
        HStack(spacing: 14) {
            switch source {
            case .article, .txt:
                Button { fontSize = max(12, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                Text("\(Int(fontSize))").font(.caption.monospacedDigit())
                Button { fontSize = min(28, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                Divider().frame(height: 16)
                themeDots
                Text("\(Int(scrollFraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            case .epub:
                Button { if epubIndex > 0 { epubIndex -= 1 } } label: { Image(systemName: "chevron.left") }.disabled(epubIndex <= 0)
                Text("\(epubIndex + 1)/\(epubChapters.count)").font(.caption.monospacedDigit())
                Button { if epubIndex + 1 < epubChapters.count { epubIndex += 1 } } label: { Image(systemName: "chevron.right") }.disabled(epubIndex + 1 >= epubChapters.count)
                Divider().frame(height: 16)
                Button { fontSize = max(12, fontSize - 1) } label: { Image(systemName: "minus") }
                Button { fontSize = min(28, fontSize + 1) } label: { Image(systemName: "plus") }
                themeDots
            case .pdf:
                if pdfTotal > 1 {
                    Slider(value: Binding(get: { Double(pdfPage) }, set: { pdfPage = Int($0); pdfJump = Int($0) }),
                           in: 1...Double(pdfTotal), step: 1)
                        .frame(maxWidth: 180)
                    Text("\(pdfPage)/\(pdfTotal)").font(.caption.monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 16)
    }

    private var themeDots: some View {
        HStack(spacing: 6) {
            ForEach([AppTheme.cinemaDark, .lightEditorial, .sepia]) { t in
                Circle().fill(t.backgroundColor).frame(width: 20, height: 20)
                    .overlay { Circle().stroke(t == theme ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: t == theme ? 2 : 1) }
                    .onTapGesture { theme = t }
            }
        }
    }

    private var tocSheet: some View {
        NavigationStack {
            List {
                if case .txt = source {
                    ForEach(Array(txtChapters.enumerated()), id: \.offset) { _, ch in
                        Button(ch.title) { showTOC = false }
                    }
                } else if case .epub = source {
                    ForEach(Array(epubChapters.enumerated()), id: \.offset) { idx, ch in
                        Button(ch.title) { epubIndex = idx; showTOC = false }
                            .foregroundStyle(idx == epubIndex ? Color.accentColor : theme.textColor)
                    }
                }
            }
            .navigationTitle("目录")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showTOC = false } } }
        }
    }

    private func load() async {
        isLoading = true; error = nil
        do {
            switch source {
            case .article(let item, let defID, _, _):
                articleDoc = try await session.extractArticle(url: item.pageURL, fallbackTitle: item.title, definitionID: defID)
            case .txt(let url, _):
                let text: String = try await Task.detached(priority: .userInitiated) {
                    let maxBytes = 50 * 1024 * 1024
                    let data = try Data(contentsOf: url)
                    guard data.count <= maxBytes else { throw ReaderSafetyError.message("文本文件超过 50 MB 上限") }
                    let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                    guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) else {
                        throw ReaderSafetyError.message("无法识别小说文件编码")
                    }
                    return s
                }.value
                txtText = text
            case .epub(let url, let history):
                let parsed = try await Task.detached(priority: .userInitiated) { try EPUBParser.parse(fileURL: url) }.value
                epubChapters = parsed
                if let p = history?.progress, !parsed.isEmpty { epubIndex = ReadingHistory.restoredIndex(progress: p, count: parsed.count) }
            case .pdf: break
            }
            isLoading = false
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false }
        }
    }

    private func saveProgress() {
        switch source {
        case .article(let item, let defID, _, let h) where articleDoc != nil:
            ReadingHistory.recordProgress(in: context, historyItem: h, title: articleDoc?.title ?? item.title,
                                          url: item.pageURL.absoluteString, fileType: .article,
                                          progress: scrollFraction, thumbnailURLString: item.thumbnail?.absoluteString, definitionID: defID)
        case .txt(let url, let h) where !txtText.isEmpty:
            ReadingHistory.recordProgress(in: context, historyItem: h, title: url.deletingPathExtension().lastPathComponent,
                                          filePath: url.path, fileType: .txt, progress: scrollFraction)
        case .epub(let url, let h) where !epubChapters.isEmpty:
            ReadingHistory.recordProgress(in: context, historyItem: h, title: url.deletingPathExtension().lastPathComponent,
                                          filePath: url.path, fileType: .epub, progress: Double(epubIndex + 1) / Double(epubChapters.count))
        case .pdf(let url, let h) where pdfTotal > 0:
            ReadingHistory.recordProgress(in: context, historyItem: h, title: url.deletingPathExtension().lastPathComponent,
                                          filePath: url.path, fileType: .pdf, progress: Double(pdfPage) / Double(pdfTotal))
        default: break
        }
    }
}

// MARK: - EPUB Parser & Contained WebView

struct EPUBChapter: Identifiable, Sendable {
    let id = UUID(); let title: String; let htmlURL: URL; let rootURL: URL
}

enum EPUBParser {
    static func parse(fileURL: URL) throws -> [EPUBChapter] {
        let vals = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = SHA256.hash(data: Data("\(fileURL.standardizedFileURL.absoluteString)|\(vals.fileSize ?? 0)|\(vals.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("epub-" + key, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) { _ = try ReaderArchive.extract(archiveURL: fileURL, to: dir) }

        guard let container = FileManager.default.contents(atPath: dir.appendingPathComponent("META-INF/container.xml").path) else {
            throw ReaderSafetyError.message("找不到 container.xml")
        }
        let cp = SAXParser(data: container); cp.parse()
        guard let opfRel = cp.attrs("rootfile").first?["full-path"] else { throw ReaderSafetyError.message("找不到 OPF 文件") }
        let opfURL = try ReaderContainedPath.resolve(opfRel.removingPercentEncoding ?? opfRel, under: dir)
        guard let opfData = FileManager.default.contents(atPath: opfURL.path) else { throw ReaderSafetyError.message("无法读取 OPF") }

        let opf = SAXParser(data: opfData); opf.parse()
        var manifest: [String: String] = [:]
        for item in opf.attrs("item") { if let id = item["id"], let href = item["href"] { manifest[id] = href } }
        let base = opfURL.deletingLastPathComponent()
        return try opf.attrs("itemref").compactMap { ref in
            guard let idref = ref["idref"], let href = manifest[idref] else { return nil }
            guard let comps = URLComponents(string: href), comps.scheme == nil, comps.host == nil else {
                throw ReaderSafetyError.message("EPUB 章节引用超出文档范围")
            }
            let html = try ReaderContainedPath.resolve(comps.path, under: dir, relativeTo: base)
            let title = href.components(separatedBy: "/").last?.replacingOccurrences(of: ".xhtml", with: "").replacingOccurrences(of: ".html", with: "") ?? href
            return EPUBChapter(title: title, htmlURL: html, rootURL: dir)
        }
    }

    private final class SAXParser: NSObject, XMLParserDelegate {
        private let data: Data
        private var elements: [String: [[String: String]]] = [:]
        init(data: Data) { self.data = data }
        func parse() { let p = XMLParser(data: data); p.shouldProcessNamespaces = true; p.delegate = self; p.parse() }
        func attrs(_ name: String) -> [[String: String]] { elements[name] ?? [] }
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            elements[name, default: []].append(attributes)
        }
    }
}

private struct EPUBWebView: UIViewRepresentable {
    let chapter: EPUBChapter; let fontSize: Double; let theme: AppTheme; let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration(); cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.delegate = context.coordinator
        wv.addGestureRecognizer(tap)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        let css = styleCSS
        let changed = context.coordinator.css != css
        context.coordinator.css = css
        if context.coordinator.loaded != chapter.htmlURL {
            context.coordinator.loaded = chapter.htmlURL
            wv.loadFileURL(chapter.htmlURL, allowingReadAccessTo: chapter.rootURL)
        } else if changed && !wv.isLoading { context.coordinator.apply(to: wv) }
    }

    private var styleCSS: String {
        let dark = (theme.colorScheme ?? colorScheme) == .dark
        let bg = theme == .sepia ? "#faf2de" : (dark ? "#0b0b0e" : "#f7f6f2")
        let fg = theme == .sepia ? "#4d381f" : (dark ? "#ebebeb" : "#1c1c1e")
        return "body{font-size:\(Int(fontSize))px;line-height:1.7;margin:68px 18px;background:\(bg)!important;color:\(fg)!important;font-family:sans-serif;}img{max-width:100%;height:auto;}"
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var parent: EPUBWebView; var loaded: URL?; var css = ""
        init(_ parent: EPUBWebView) { self.parent = parent }
        @objc func tapped() { parent.onTap() }
        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) { apply(to: wv) }
        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.isFileURL else { decisionHandler(.cancel); return }
            let root = parent.chapter.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
            let target = url.standardizedFileURL.resolvingSymlinksInPath().path
            decisionHandler((target == root || target.hasPrefix(root == "/" ? "/" : root + "/")) ? .allow : .cancel)
        }
        func apply(to wv: WKWebView) {
            wv.callAsyncJavaScript("let s=document.getElementById('cove-s');if(!s){s=document.createElement('style');s.id='cove-s';document.head.appendChild(s);}s.textContent=css;",
                                   arguments: ["css": css], in: nil, in: .defaultClient, completionHandler: nil)
        }
        func gestureRecognizer(_ gr: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - PDFKit & Fallback Web Browser

private struct PDFKitView: UIViewRepresentable {
    let url: URL; var initialProgress: Double?; @Binding var jumpToPage: Int?
    let onPage: (Int, Int) -> Void; let onFail: () -> Void; let onTap: () -> Void

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical
        if let doc = PDFDocument(url: url), doc.pageCount > 0 {
            v.document = doc
            let idx = initialProgress.map { ReadingHistory.restoredIndex(progress: $0, count: doc.pageCount) } ?? 0
            if idx > 0, let p = doc.page(at: idx) { v.go(to: p) }
            DispatchQueue.main.async { onPage(idx + 1, doc.pageCount) }
        } else { DispatchQueue.main.async { onFail() } }
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed), name: .PDFViewPageChanged, object: v)
        context.coordinator.pdfView = v
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        context.coordinator.parent = self
        if let t = jumpToPage, let doc = v.document, (1...doc.pageCount).contains(t), let p = doc.page(at: t - 1) {
            v.go(to: p); DispatchQueue.main.async { jumpToPage = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: PDFKitView; weak var pdfView: PDFView?
        init(_ parent: PDFKitView) { self.parent = parent }
        @objc func tapped() { parent.onTap() }
        @objc func changed() {
            guard let pdfView, let doc = pdfView.document, let page = pdfView.currentPage else { return }
            parent.onPage(doc.index(for: page) + 1, doc.pageCount)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct WebBrowserView: View {
    let url: URL
    var onClose: (() -> Void)? = nil
    @State private var webView = WebScript.makeWebView(gestures: true)
    @State private var canGoBack = false

    var body: some View {
        WebHost(webView: webView, canGoBack: $canGoBack)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                HStack(spacing: 22) {
                    Button { webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!canGoBack)
                    Button { webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    if let onClose { Button("画廊模式", action: onClose).font(.caption.weight(.medium)) }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 16)
            }
            .onAppear {
                if webView.url == nil { webView.load(WebURLSafety.makeRequest(url: url)) }
                Task { await ContentBlocker.sync(to: webView) }
            }
    }

    private struct WebHost: UIViewRepresentable {
        let webView: WKWebView; @Binding var canGoBack: Bool
        func makeUIView(context: Context) -> WKWebView { webView.navigationDelegate = context.coordinator; return webView }
        func updateUIView(_ uiView: WKWebView, context: Context) {}
        func makeCoordinator() -> Coord { Coord(canGoBack: $canGoBack) }
        @MainActor final class Coord: NSObject, WKNavigationDelegate {
            @Binding var canGoBack: Bool
            init(canGoBack: Binding<Bool>) { _canGoBack = canGoBack }
            nonisolated func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                Task { @MainActor in canGoBack = webView.canGoBack }
            }
        }
    }
}
