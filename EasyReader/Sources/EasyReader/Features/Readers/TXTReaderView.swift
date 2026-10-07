import SwiftUI
import SwiftData
import CoreText

// MARK: - Data types

struct PageContent: Identifiable {
    let id: Int
    let text: String
    let chapterTitle: String?
}

struct Chapter: Identifiable {
    let id: Int
    let title: String
    let location: Int   // character offset in full text
    let pageIndex: Int
}

// MARK: - Paginator

enum TextPaginator {

    static func paginate(
        text: String,
        font: UIFont,
        lineSpacing: CGFloat,
        containerSize: CGSize,
        insets: UIEdgeInsets,
        chapters: [Chapter]
    ) async -> [PageContent] {
        await Task.detached(priority: .userInitiated) {
            let drawSize = CGSize(
                width:  containerSize.width  - insets.left - insets.right,
                height: containerSize.height - insets.top  - insets.bottom
            )
            guard drawSize.width > 0, drawSize.height > 0 else { return [] }

            // Pre-sorted chapter locations for O(log N) lookup per page
            let sortedLocs = chapters.map(\.location).sorted()
            let locToTitle: [Int: String] = Dictionary(
                chapters.map { ($0.location, $0.title) },
                uniquingKeysWith: { first, _ in first }
            )

            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
            let attrString = NSAttributedString(string: text, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(attrString)
            let totalLength = attrString.length
            var pages: [PageContent] = []
            var startIndex = 0

            while startIndex < totalLength {
                let path = CGPath(rect: CGRect(origin: .zero, size: drawSize), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(startIndex, 0), path, nil)
                let visibleRange = CTFrameGetVisibleStringRange(frame)
                guard visibleRange.length > 0 else { break }

                let nsRange = NSRange(location: visibleRange.location, length: visibleRange.length)
                let pageText = (text as NSString).substring(with: nsRange)

                // Binary search: find the last chapter starting at or before this page
                var chapterTitle: String? = nil
                if !sortedLocs.isEmpty {
                    var lo = 0, hi = sortedLocs.count
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if sortedLocs[mid] <= visibleRange.location { lo = mid + 1 } else { hi = mid }
                    }
                    if lo > 0 { chapterTitle = locToTitle[sortedLocs[lo - 1]] }
                }

                pages.append(PageContent(id: pages.count, text: pageText, chapterTitle: chapterTitle))
                startIndex = visibleRange.location + visibleRange.length
            }
            return pages
        }.value
    }

    // Pre-compiled chapter detection regex patterns
    private static let chapterRegexes: [NSRegularExpression] = {
        let specs: [(pattern: String, options: NSRegularExpression.Options)] = [
            (#"第[一二三四五六七八九十百千万零\d]{1,8}[章节回话篇集卷]\s*[^\n]*"#, []),
            (#"Chapter\s+\d+[^\n]*"#, []),
            (#"CHAPTER\s+\d+[^\n]*"#, []),
            (#"^卷[一二三四五六七八九十\d]{1,4}\s*[^\n]*"#, [.anchorsMatchLines])
        ]
        return specs.compactMap { try? NSRegularExpression(pattern: $0.pattern, options: $0.options) }
    }()

    static func detectChapters(in text: String) -> [Chapter] {
        let nsText = text as NSString
        var results: [(location: Int, title: String)] = []
        for regex in chapterRegexes {
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let title = nsText.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { results.append((match.range.location, title)) }
            }
        }
        results.sort { $0.location < $1.location }
        var seen = Set<Int>()
        var chapters: [Chapter] = []
        for r in results {
            guard !seen.contains(r.location) else { continue }
            seen.insert(r.location)
            chapters.append(Chapter(id: chapters.count, title: r.title, location: r.location, pageIndex: 0))
        }
        return chapters
    }

    static func assignPageIndices(chapters: inout [Chapter], pages: [PageContent]) {
        guard !chapters.isEmpty, !pages.isEmpty else { return }
        // Build cumulative character offsets for each page — O(pages)
        var offsets: [Int] = []
        offsets.reserveCapacity(pages.count)
        var cumulative = 0
        for page in pages {
            offsets.append(cumulative)
            cumulative += (page.text as NSString).length
        }
        // For each chapter, binary search for the page containing its location — O(chapters * log(pages))
        for i in chapters.indices {
            let loc = chapters[i].location
            var lo = 0, hi = offsets.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if offsets[mid] <= loc { lo = mid + 1 } else { hi = mid }
            }
            let pageIdx = max(lo - 1, 0)
            chapters[i] = Chapter(id: chapters[i].id, title: chapters[i].title,
                                  location: chapters[i].location, pageIndex: pageIdx)
        }
    }
}

// MARK: - TXTReaderView

struct TXTReaderView: View {
    let fileURL: URL
    var historyItem: ReadingHistory?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @AppStorage("readerTheme")    private var theme: ReaderTheme = .system
    @AppStorage("readerLineSpacing") private var lineSpacing: Double = 8

    @State private var fullText = ""
    @State private var pages: [PageContent] = []
    @State private var chapters: [Chapter] = []
    @State private var currentPage = 0
    @State private var isLoading = true
    @State private var isPaginating = false
    @State private var loadError: String?
    @State private var showBars = false
    @State private var showChapterList = false
    @State private var containerSize: CGSize = .zero
    @State private var dragOffset: CGFloat = 0

    private var backgroundColor: Color {
        switch theme {
        case .dark:   Color.black
        case .sepia:  Color(red: 0.98, green: 0.95, blue: 0.87)
        case .light:  Color.white
        case .system: Color(UIColor.systemBackground)
        }
    }

    private var textColor: Color {
        switch theme {
        case .dark:   Color(white: 0.85)
        case .sepia:  Color(red: 0.30, green: 0.22, blue: 0.12)
        case .light:  Color.black
        case .system: Color(UIColor.label)
        }
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            // Hidden GeometryReader always present to capture container size
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        let s = geo.size
                        if s.width > 0, s.height > 0, containerSize != s {
                            containerSize = s
                            if !fullText.isEmpty { repaginate() }
                        }
                    }
                    .onChange(of: geo.size) { _, s in
                        if s.width > 0, s.height > 0, containerSize != s {
                            containerSize = s
                            if !fullText.isEmpty { repaginate() }
                        }
                    }
            }

            if isLoading {
                loadingView.overlay(alignment: .topLeading) { floatingBackButton }
            } else if let loadError {
                errorView(loadError)
            } else if isPaginating {
                paginatingView.overlay(alignment: .topLeading) { floatingBackButton }
            } else if pages.isEmpty {
                ContentUnavailableView {
                    Label("空文件", systemImage: "doc.text")
                } actions: {
                    Button("返回") { dismiss() }
                }
            } else {
                pageContentView
                if showBars {
                    VStack(spacing: 0) { topBar; Spacer(); bottomBar }
                        .transition(.opacity)
                }
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showBars)
        .task { await loadFile() }
        .onDisappear { saveProgress() }
        .onChange(of: fontSize) { repaginate() }
        .onChange(of: lineSpacing) { repaginate() }
        .sheet(isPresented: $showChapterList) { chapterListSheet }
        .preferredColorScheme(theme == .dark ? .dark : theme == .system ? nil : .light)
    }

    // MARK: - Page content + swipe / tap

    private var pageContentView: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                // Only render current page — O(1) instead of O(pages.count)
                if pages.indices.contains(currentPage) {
                    pageView(pages[currentPage])
                        .offset(x: dragOffset)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only allow horizontal-dominant drags
                        let h = abs(value.translation.width)
                        let v = abs(value.translation.height)
                        guard h > v else { return }
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let threshold = w * 0.25
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        if value.translation.width + velocity < -threshold, currentPage < pages.count - 1 {
                            // Swipe left → next page
                            withAnimation(.easeOut(duration: 0.2)) { dragOffset = -w }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                dragOffset = 0; currentPage += 1
                            }
                        } else if value.translation.width + velocity > threshold, currentPage > 0 {
                            // Swipe right → previous page
                            withAnimation(.easeOut(duration: 0.2)) { dragOffset = w }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                dragOffset = 0; currentPage -= 1
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) { dragOffset = 0 }
                        }
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    // no-op: tap location handled below
                }
            )
            // Tap zones overlaid on top
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { if currentPage > 0 { currentPage -= 1 } }
                        .frame(width: w / 3)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() } }
                        .frame(width: w / 3)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { if currentPage < pages.count - 1 { currentPage += 1 } }
                        .frame(width: w / 3)
                }
            }
        }
    }

    private func pageView(_ page: PageContent) -> some View {
        Text(page.text)
            .font(.system(size: fontSize))
            .lineSpacing(lineSpacing)
            .foregroundStyle(textColor)
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Loading views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("加载中…").font(.subheadline).foregroundStyle(.secondary)
            Text(fileURL.lastPathComponent).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func errorView(_ msg: String) -> some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "doc.text")
        } description: { Text(msg) } actions: {
            Button("重试") { Task { await loadFile() } }.buttonStyle(.borderedProminent)
            Button("返回") { dismiss() }
        }
    }

    private var paginatingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("排版中…").font(.subheadline).foregroundStyle(.secondary)
        }
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
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").imageScale(.large).fontWeight(.medium)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(fileURL.deletingPathExtension().lastPathComponent)
                    .font(.headline).lineLimit(1)
                if pages.indices.contains(currentPage),
                   let ch = pages[currentPage].chapterTitle {
                    Text(ch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !chapters.isEmpty {
                Button { showChapterList = true } label: {
                    Image(systemName: "list.bullet").imageScale(.large)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if pages.count > 1 {
                HStack(spacing: 12) {
                    Text("\(currentPage + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(currentPage) },
                        set: { currentPage = Int($0) }
                    ), in: 0...Double(max(pages.count - 1, 0)), step: 1)
                    Text("\(pages.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 20) {
                HStack(spacing: 8) {
                    Button { if fontSize > 12 { fontSize -= 1 } } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    Text("\(Int(fontSize))pt").font(.caption).monospacedDigit().frame(width: 36)
                    Button { if fontSize < 28 { fontSize += 1 } } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                }
                Divider().frame(height: 20)
                HStack(spacing: 12) {
                    ForEach(ReaderTheme.allCases) { t in
                        Circle()
                            .fill(themeDotColor(t))
                            .frame(width: 26, height: 26)
                            .overlay { Circle().stroke(t == theme ? Color.accentColor : .clear, lineWidth: 2) }
                            .onTapGesture { theme = t }
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func themeDotColor(_ t: ReaderTheme) -> Color {
        switch t {
        case .system: Color(UIColor.secondarySystemBackground)
        case .light:  .white
        case .dark:   .black
        case .sepia:  Color(red: 0.98, green: 0.95, blue: 0.87)
        }
    }

    // MARK: - Chapter list

    private var chapterListSheet: some View {
        NavigationStack {
            List(chapters) { ch in
                Button {
                    currentPage = ch.pageIndex
                    showChapterList = false
                    showBars = false
                } label: {
                    HStack {
                        Text(ch.title).lineLimit(2)
                        Spacer()
                        Text("p.\(ch.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("目录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showChapterList = false } }
            }
        }
    }

    // MARK: - Load

    private func loadFile() async {
        loadError = nil; isLoading = true
        do {
            fullText = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            if let data = try? Data(contentsOf: fileURL),
               let text = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
                fullText = text
            } else {
                loadError = error.localizedDescription; isLoading = false; return
            }
        }
        isLoading = false
        chapters = TextPaginator.detectChapters(in: fullText)
        await paginateText()
    }

    private func repaginate() {
        guard !fullText.isEmpty, containerSize != .zero else { return }
        Task { await paginateText() }
    }

    private func paginateText() async {
        isPaginating = true
        // Wait for containerSize — GeometryReader will set it and call repaginate()
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        let savedProgress: Double = pages.isEmpty
            ? (historyItem?.progress ?? 0)
            : Double(currentPage) / Double(max(pages.count, 1))

        let result = await TextPaginator.paginate(
            text: fullText,
            font: UIFont.systemFont(ofSize: fontSize),
            lineSpacing: lineSpacing,
            containerSize: containerSize,
            insets: UIEdgeInsets(top: 60, left: 20, bottom: 80, right: 20),
            chapters: chapters
        )
        TextPaginator.assignPageIndices(chapters: &chapters, pages: result)
        pages = result
        isPaginating = false

        if !pages.isEmpty {
            currentPage = min(Int(savedProgress * Double(pages.count - 1)), pages.count - 1)
        }
    }

    private func saveProgress() {
        let p = pages.isEmpty ? 0 : Double(currentPage) / Double(max(pages.count - 1, 1))
        if let item = historyItem {
            item.progress = p; item.lastReadAt = Date()
        } else {
            context.insert(ReadingHistory(
                title: fileURL.deletingPathExtension().lastPathComponent,
                filePath: fileURL.path, fileType: .txt, progress: p
            ))
        }
    }
}
