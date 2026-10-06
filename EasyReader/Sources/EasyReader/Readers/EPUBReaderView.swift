import SwiftUI
import WebKit
import ZIPFoundation
import SwiftData

/// EPUB reader: unzips the archive, parses OPF manifest, renders chapters in WKWebView.
struct EPUBReaderView: View {
    let fileURL: URL
    var title: String? = nil
    var historyItem: LibraryEntry?

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @AppStorage("readerTheme")    private var theme: ReaderTheme = .system

    @State private var chapters: [EPUBChapter] = []
    @State private var document: ArchiveDocument?
    @State private var currentChapter = 0
    @State private var isLoading = true
    @State private var showBars  = true
    @State private var showTOC   = false
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("解析中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(title ?? fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) { floatingBackButton }
            } else if let error {
                ContentUnavailableView {
                    Label("解析失败", systemImage: "book.closed")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await parseEPUB() } }.buttonStyle(.borderedProminent)
                    Button("返回") { dismiss() }
                }
            } else if chapters.isEmpty {
                ContentUnavailableView {
                    Label("无法解析章节", systemImage: "book.closed")
                } actions: {
                    Button("返回") { dismiss() }
                }
            } else {
                EPUBWebView(chapter: chapters[currentChapter], root: document!.root, fontSize: fontSize, theme: theme, onFailure: { error = $0 }) {
                    withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                }
                .ignoresSafeArea()
            }

            if showBars && !isLoading && error == nil {
                VStack(spacing: 0) { topBar; Spacer(); bottomBar }
                    .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showBars)
        .sheet(isPresented: $showTOC) { tocSheet }
        .task { await parseEPUB() }
        .onDisappear { saveProgress() }
    }

    private var floatingBackButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 12)
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.left").imageScale(.large) }
            Spacer()
            Text(title ?? fileURL.deletingPathExtension().lastPathComponent)
                .font(.headline).lineLimit(1)
            Spacer()
            Button { showTOC = true } label: { Image(systemName: "list.bullet") }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        HStack(spacing: 24) {
            Button { if currentChapter > 0 { currentChapter -= 1 } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentChapter == 0)
            Spacer()
            Text("\(currentChapter + 1) / \(chapters.count)")
                .foregroundStyle(.secondary)
            Spacer()
            Button { if currentChapter < chapters.count - 1 { currentChapter += 1 } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(currentChapter >= chapters.count - 1)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var tocSheet: some View {
        NavigationStack {
            List(Array(chapters.enumerated()), id: \.offset) { idx, ch in
                Button(ch.title) {
                    currentChapter = idx
                    showTOC = false
                }
                .foregroundStyle(idx == currentChapter ? Color.accentColor : .primary)
            }
            .navigationTitle("目录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showTOC = false }
                }
            }
        }
    }

    // MARK: - EPUB parsing

    private func parseEPUB() async {
        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                try EPUBParser.parse(fileURL: self.fileURL)
            }.value
            await MainActor.run {
                document = parsed.document
                chapters = parsed.chapters
                currentChapter = min(max(0, Int(historyItem?.position ?? 0)), max(0, chapters.count - 1))
                isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func saveProgress() {
        guard let item = historyItem else { return }
        item.progress = chapters.isEmpty ? 0 : Double(currentChapter) / Double(max(chapters.count - 1, 1))
        item.position = Double(currentChapter)
        item.lastOpenedAt = .now
        do { try library.persist() } catch { library.error = error.localizedDescription }
    }
}

// MARK: - Chapter model

struct EPUBChapter: Identifiable, Sendable {
    let id    = UUID()
    let title : String
    let htmlURL: URL    // extracted HTML file path
}

// MARK: - EPUB parser (OPF-based)

enum EPUBParser {
    struct Book: Sendable { let document: ArchiveDocument; let chapters: [EPUBChapter] }
    static func parse(fileURL: URL) throws -> Book {
        let document = try ArchiveService.open(fileURL)
        let containerPath = document.root.appendingPathComponent("META-INF/container.xml")
        let containerData = try Data(contentsOf: containerPath)
        let opfPath = try parseContainerXML(data: containerData, base: document.root)
        return Book(document: document, chapters: try parseOPF(at: opfPath, base: document.root))
    }

    private static func parseContainerXML(data: Data, base: URL) throws -> URL {
        let parser = SimpleXMLParser(data: data)
        try parser.parse()
        guard let path = parser.firstAttribute(element: "rootfile", attribute: "full-path") else {
            throw EPUBError.missingOPF
        }
        return try ContainedPath.resolve(path, under: base)
    }

    private static func parseOPF(at opfURL: URL, base: URL) throws -> [EPUBChapter] {
        guard let data = FileManager.default.contents(atPath: opfURL.path) else {
            throw EPUBError.missingOPF
        }
        let opfBase = opfURL.deletingLastPathComponent()
        let parser  = SimpleXMLParser(data: data)
        try parser.parse()

        // Build id→href manifest from <item> elements
        var manifest: [String: String] = [:]
        for attrs in parser.allAttributes(element: "item") {
            if let id = attrs["id"], let href = attrs["href"] {
                manifest[id] = href
            }
        }

        // Spine reading order from <itemref> elements
        var chapters: [EPUBChapter] = []
        for attrs in parser.allAttributes(element: "itemref") {
            guard let idref = attrs["idref"], let href = manifest[idref] else { continue }
            guard let components = URLComponents(string: href), components.scheme == nil, components.host == nil,
                  let path = components.percentEncodedPath.removingPercentEncoding else {
                throw CoveError.message("EPUB 章节引用无效")
            }
            let htmlURL = try ContainedPath.resolve(path, under: base, relativeTo: opfBase)
            let title   = href.components(separatedBy: "/").last?
                            .replacingOccurrences(of: ".xhtml", with: "")
                            .replacingOccurrences(of: ".html", with: "") ?? href
            chapters.append(EPUBChapter(title: title, htmlURL: htmlURL))
        }
        return chapters
    }
}

// MARK: - Minimal SAX XML parser (iOS-compatible replacement for XMLDocument)

private final class SimpleXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    // element name → array of attribute dicts (one per occurrence)
    private var elements: [String: [[String: String]]] = [:]

    init(data: Data) { self.data = data }

    func parse() throws {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldResolveExternalEntities = false
        guard p.parse() else { throw p.parserError ?? CoveError.message("EPUB XML 文件无效") }
    }

    func firstAttribute(element: String, attribute: String) -> String? {
        elements[element]?.first?[attribute]
    }

    func allAttributes(element: String) -> [[String: String]] {
        elements[element] ?? []
    }

    // XMLParserDelegate
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        elements[elementName, default: []].append(attributes)
    }
}

enum EPUBError: LocalizedError {
    case invalidArchive, missingContainer, missingOPF
    var errorDescription: String? {
        switch self {
        case .invalidArchive:   "无效的 EPUB 文件"
        case .missingContainer: "找不到 container.xml"
        case .missingOPF:       "找不到 OPF 文件"
        }
    }
}

// MARK: - WKWebView for EPUB chapters

struct EPUBWebView: UIViewRepresentable {
    let chapter: EPUBChapter
    let root: URL
    let fontSize: Double
    let theme: ReaderTheme
    var onFailure: ((String) -> Void)? = nil
    var onTap: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let coordinator = context.coordinator
        Task { @MainActor in
            do { try await WebContentPolicy.installEPUB(view); coordinator.ready = true; coordinator.parent.load(view, coordinator: coordinator) }
            catch { coordinator.parent.onFailure?(error.localizedDescription) }
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        load(view, coordinator: context.coordinator)
    }
    private func load(_ view: WKWebView, coordinator: Coordinator) {
        guard coordinator.ready else { return }
        if coordinator.loaded != chapter.htmlURL {
            coordinator.loaded = chapter.htmlURL
            view.loadFileURL(chapter.htmlURL, allowingReadAccessTo: root)
        } else if coordinator.fontSize != fontSize || coordinator.theme != theme {
            coordinator.applyStyle(view)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var parent: EPUBWebView
        var ready = false
        var loaded: URL?
        var fontSize: Double?
        var theme: ReaderTheme?
        init(_ parent: EPUBWebView) { self.parent = parent }
        @objc func handleTap() { parent.onTap() }
        func gestureRecognizer(_ gr: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { applyStyle(view) }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let root = parent.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return url.isFileURL && url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) ? .allow : .cancel
        }
        func applyStyle(_ view: WKWebView) {
            fontSize = parent.fontSize; theme = parent.theme
            let dark = parent.theme == .dark || (parent.theme == .system && view.traitCollection.userInterfaceStyle == .dark)
            let background = parent.theme == .sepia ? "#fdf6e3" : (dark ? "#1c1c1e" : "#ffffff")
            let foreground = dark ? "#f0f0f0" : "#1c1c1e"
            let css = "body {font-size: \(Int(parent.fontSize))px; line-height:1.7; margin:16px; background:\(background);color:\(foreground);font-family:-apple-system,'PingFang SC',sans-serif;} img{max-width:100%;height:auto;}"
            let script = "let s=document.getElementById('cove-style');if(!s){s=document.createElement('style');s.id='cove-style';document.head.appendChild(s);}s.textContent=" + ScriptJSON.encode(css) + ";"
            view.evaluateJavaScript(script)
        }
    }
}
