import SwiftUI
import WebKit
import ZIPFoundation
import SwiftData

/// EPUB reader: unzips the archive, parses OPF manifest, renders chapters in WKWebView.
struct EPUBReaderView: View {
    let fileURL: URL
    var historyItem: ReadingHistory?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @AppStorage("readerTheme")    private var theme: ReaderTheme = .system

    @State private var chapters: [EPUBChapter] = []
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
                    Text(fileURL.lastPathComponent)
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
                EPUBWebView(chapter: chapters[currentChapter], fontSize: fontSize, theme: theme) {
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
            Text(fileURL.deletingPathExtension().lastPathComponent)
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
                chapters = parsed
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
        let p = chapters.isEmpty ? 0 : Double(currentChapter + 1) / Double(chapters.count)
        if let item = historyItem {
            item.progress = p; item.lastReadAt = Date()
        } else {
            context.insert(ReadingHistory(
                title: fileURL.deletingPathExtension().lastPathComponent,
                filePath: fileURL.path,
                fileType: .epub,
                progress: p
            ))
        }
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
    static func parse(fileURL: URL) throws -> [EPUBChapter] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "_epub")

        // Extract if needed
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            guard let archive = Archive(url: fileURL, accessMode: .read) else {
                throw EPUBError.invalidArchive
            }
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for entry in archive {
                let dest = tempDir.appendingPathComponent(entry.path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: dest)
            }
        }

        // Find container.xml → OPF path
        let containerPath = tempDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = FileManager.default.contents(atPath: containerPath.path) else {
            throw EPUBError.missingContainer
        }
        let opfPath = try parseContainerXML(data: containerData, base: tempDir)
        return try parseOPF(at: opfPath, base: tempDir)
    }

    private static func parseContainerXML(data: Data, base: URL) throws -> URL {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        guard let path = parser.firstAttribute(element: "rootfile", attribute: "full-path") else {
            throw EPUBError.missingOPF
        }
        return base.appendingPathComponent(path)
    }

    private static func parseOPF(at opfURL: URL, base: URL) throws -> [EPUBChapter] {
        guard let data = FileManager.default.contents(atPath: opfURL.path) else {
            throw EPUBError.missingOPF
        }
        let opfBase = opfURL.deletingLastPathComponent()
        let parser  = SimpleXMLParser(data: data)
        parser.parse()

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
            let htmlURL = opfBase.appendingPathComponent(href)
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

    func parse() {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
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
    let chapter : EPUBChapter
    let fontSize : Double
    let theme    : ReaderTheme
    var onTap    : () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.delegate = context.coordinator
        wv.addGestureRecognizer(tap)
        load(into: wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        load(into: uiView)
    }

    private func load(into wv: WKWebView) {
        let bgColor  = theme == .sepia ? "#fdf6e3" : (theme == .dark ? "#1c1c1e" : "#ffffff")
        let txtColor = theme == .dark  ? "#f0f0f0" : "#1c1c1e"
        let css = """
        <style>
        body { font-size: \(Int(fontSize))px; line-height: 1.7; margin: 16px;
               background: \(bgColor); color: \(txtColor);
               font-family: -apple-system, 'PingFang SC', sans-serif; }
        img  { max-width: 100%; height: auto; }
        </style>
        """
        wv.loadFileURL(chapter.htmlURL, allowingReadAccessTo: chapter.htmlURL.deletingLastPathComponent())
        wv.evaluateJavaScript("document.head.insertAdjacentHTML('beforeend', `\(css)`)")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var parent: EPUBWebView
        init(_ parent: EPUBWebView) { self.parent = parent }

        @objc func handleTap() { parent.onTap() }
        func gestureRecognizer(
            _ gr: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
