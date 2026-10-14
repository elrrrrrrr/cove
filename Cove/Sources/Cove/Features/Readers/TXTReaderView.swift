import SwiftUI
import SwiftData
import CoreText

// MARK: - Data types

struct PageContent: Identifiable, Sendable {
    let id: Int
    let text: String
    let chapterTitle: String?
}

struct Chapter: Identifiable, Sendable {
    let id: Int
    let title: String
    let location: Int   // character offset in full text
    let pageIndex: Int
}

// MARK: - Paginator

enum TextPaginator {

    static func load(_ url: URL) async throws -> (text: String, chapters: [Chapter]) {
        let work = Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: encoding) else {
                throw ReaderSafetyError.message("无法识别小说文件编码")
            }
            try Task.checkCancellation()
            return (text: text, chapters: detectChapters(in: text))
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func paginate(
        text: String,
        font: UIFont,
        lineSpacing: CGFloat,
        containerSize: CGSize,
        insets: UIEdgeInsets,
        chapters: [Chapter]
    ) async -> [PageContent] {
        let work = Task<[PageContent], Never>.detached(priority: .userInitiated) {
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
                guard !Task.isCancelled else { return [] as [PageContent] }
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
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
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
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @AppStorage(NovelReadingMode.storageKey) private var readingMode: NovelReadingMode = .paged
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
    @State private var scrollPage: Int?
    @State private var paginationTask: Task<Void, Never>?
    @State private var paginationRevision = 0
    @State private var restoredProgress: Double = 0
    @State private var scrollProgress: Double = 0

    private var backgroundColor: Color { theme.backgroundColor }
    private var textColor: Color { theme.textColor }

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
                if readingMode == .scroll { scrollingContentView }
                else { pageContentView }
                if showBars {
                    VStack(spacing: 0) { topBar; Spacer(); bottomBar }
                        .transition(.opacity)
                }
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showBars)
        .task { await loadFile() }
        .onDisappear { paginationTask?.cancel(); paginationRevision += 1; saveProgress() }
        .onChange(of: fontSize) { repaginate() }
        .onChange(of: lineSpacing) { repaginate() }
        .onChange(of: readingMode) { _, mode in
            if mode == .scroll { scrollProgress = Double(currentPage) / Double(max(pages.count - 1, 1)) }
            scrollPage = currentPage; dragOffset = 0
        }
        .onChange(of: scrollPage) { _, page in
            if readingMode == .scroll, let page { currentPage = page }
        }
        .sheet(isPresented: $showChapterList) { chapterListSheet }
        .preferredColorScheme(theme.colorScheme)
    }

    // MARK: - Page content + swipe / tap

    private var scrollingContentView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pages) { page in
                    Text(page.text).font(.system(size: fontSize)).lineSpacing(lineSpacing)
                        .foregroundStyle(textColor).fixedSize(horizontal: false, vertical: true)
                        .frame(width: max(containerSize.width - 40, 1), alignment: .leading).id(page.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.top, 60).padding(.bottom, 80)
        }
        .scrollPosition(id: $scrollPage, anchor: .top)
        .onScrollGeometryChange(for: Double.self) { geometry in
            let distance = max(geometry.contentSize.height - geometry.containerSize.height, 1)
            return min(max(Double(geometry.contentOffset.y / distance), 0), 1)
        } action: { _, progress in
            scrollProgress = progress
        }
        .accessibilityIdentifier("novel-scroll")
        .simultaneousGesture(TapGesture().onEnded { withAnimation { showBars.toggle() } })
    }

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
                        set: { selectPage(Int($0)) }
                    ), in: 0...Double(max(pages.count - 1, 0)), step: 1)
                    Text("\(pages.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
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
                HStack(spacing: 8) {
                    ForEach(AppTheme.allCases) { t in
                        Circle()
                            .fill(themeDotColor(t))
                            .frame(width: 24, height: 24)
                            .overlay { Circle().stroke(t == theme ? Color.accentColor : .clear, lineWidth: 2) }
                            .onTapGesture { theme = t }
                    }
                }
                Menu {
                    Picker("小说翻页方式", selection: $readingMode) {
                        ForEach(NovelReadingMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                } label: {
                    Image(systemName: readingMode == .scroll ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                }
                .accessibilityLabel("小说翻页方式")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func themeDotColor(_ t: AppTheme) -> Color {
        switch t {
        case .system: Color(UIColor.secondarySystemBackground)
        case .light:  .white
        case .dark:   .black
        case .sepia:  Color(red: 0.98, green: 0.95, blue: 0.87)
        }
    }

    // MARK: - Chapter list

    private var chapterListSheet: some View {
        ChapterListSheet(
            chapters: chapters,
            title: { $0.title },
            subtitle: { "p.\($0.pageIndex + 1)" },
            onSelect: { ch in
                selectPage(ch.pageIndex)
                showChapterList = false
                showBars = false
            }
        )
    }

    // MARK: - Load

    private func selectPage(_ page: Int) {
        currentPage = page
        scrollPage = page
    }

    private func loadFile() async {
        loadError = nil; isLoading = true
        let path = fileURL.path
        let stored = try? context.fetch(FetchDescriptor<ReadingHistory>(predicate: #Predicate { $0.filePath == path })).first
        restoredProgress = historyItem?.progress ?? stored?.progress ?? 0
        do {
            let loaded = try await TextPaginator.load(fileURL)
            try Task.checkCancellation()
            fullText = loaded.text
            chapters = loaded.chapters
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription; isLoading = false; return
        }
        isLoading = false
        await paginateText()
    }

    private func repaginate() {
        guard !fullText.isEmpty, containerSize != .zero else { return }
        paginationTask?.cancel()
        paginationTask = Task { await paginateText() }
    }

    private func paginateText() async {
        // Wait for containerSize — GeometryReader will set it and call repaginate()
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        isPaginating = true
        paginationRevision += 1
        let revision = paginationRevision

        let savedProgress: Double = pages.isEmpty
            ? restoredProgress
            : (readingMode == .scroll ? scrollProgress : Double(currentPage) / Double(max(pages.count - 1, 1)))

        let result = await TextPaginator.paginate(
            text: fullText,
            font: UIFont.systemFont(ofSize: fontSize),
            lineSpacing: lineSpacing,
            containerSize: containerSize,
            insets: UIEdgeInsets(top: 60, left: 20, bottom: 80, right: 20),
            chapters: chapters
        )
        guard !Task.isCancelled, paginationRevision == revision else { return }
        TextPaginator.assignPageIndices(chapters: &chapters, pages: result)
        pages = result
        isPaginating = false

        if !pages.isEmpty {
            currentPage = min(Int(savedProgress * Double(pages.count - 1)), pages.count - 1)
            scrollPage = currentPage
            scrollProgress = savedProgress
        }
    }

    private func saveProgress() {
        guard !pages.isEmpty else { return }
        let p = readingMode == .scroll ? scrollProgress : Double(currentPage) / Double(max(pages.count - 1, 1))
        let path = fileURL.path
        let stored = try? context.fetch(FetchDescriptor<ReadingHistory>(predicate: #Predicate { $0.filePath == path })).first
        if let item = historyItem ?? stored {
            item.progress = p; item.lastReadAt = Date()
        } else {
            context.insert(ReadingHistory(
                title: fileURL.deletingPathExtension().lastPathComponent,
                filePath: fileURL.path, fileType: .txt, progress: p
            ))
        }
        try? context.save()
    }
}
