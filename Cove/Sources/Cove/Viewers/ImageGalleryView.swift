import SwiftUI
import SwiftData
import Nuke

struct ImageGalleryView: View {
    enum Source {
        case webComic(item: ParsedItem, definitionID: String?)
        case localCBZ(url: URL, history: ReadingHistory?)
        case nasImages(entries: [NASFileEntry], initialIndex: Int, clientID: String)
    }

    let source: Source

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark

    // Web comic detail
    @State private var session = WebSession()
    @State private var comicDetail: ComicDetail?
    @State private var detailError: String?
    @State private var lastChapterID: String?
    @State private var activeChapter: ComicChapter?

    // Shared image strip state (chapter / CBZ / NAS images)
    @State private var imageURLs: [URL] = []
    @State private var currentPage = 0
    @State private var jumpPage: Int?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showBars = true
    @State private var showInspect = false
    @State private var extractedDir: URL?
    @State private var zoomScale: CGFloat = 1

    var body: some View {
        Group {
            switch source {
            case .webComic(let item, let defID):
                if let chapter = activeChapter, let detail = comicDetail {
                    comicChapterReader(chapter: chapter, detail: detail, bookURL: item.pageURL, defID: defID)
                } else {
                    comicDetailBody(item: item, defID: defID)
                }
            case .localCBZ(let url, let history):
                cbzReaderBody(url: url, history: history)
            case .nasImages(let entries, _, _):
                nasImageBody(entries: entries)
            }
        }
        .sheet(isPresented: $showInspect) {
            if let req = session.originalRequest { ParsingWebViewSheet(webView: session.webView, request: req) }
        }
    }

    // MARK: - 1. Online Comic Detail + Chapter Reader

    @ViewBuilder
    private func comicDetailBody(item: ParsedItem, defID: String?) -> some View {
        Group {
            if let detail = comicDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            CoveImage(url: detail.coverURL ?? item.thumbnail, referer: item.pageURL, definitionID: defID)
                                .frame(width: 120, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(detail.title.isEmpty ? item.title : detail.title).font(.title3.bold())
                                if !detail.author.isEmpty { Label(detail.author, systemImage: "person").font(.subheadline).foregroundStyle(.secondary) }
                                if !detail.status.isEmpty { Label(detail.status, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary) }
                                if !detail.description.isEmpty { Text(detail.description).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                            }
                        }.padding(.horizontal)

                        let resume = lastChapterID.flatMap { id in detail.chapters.first { $0.id == id } }
                        Button {
                            openChapter(resume ?? detail.chapters.first, defID: defID)
                        } label: {
                            Label(resume.map { "继续阅读 \($0.title)" } ?? "开始阅读", systemImage: "book.fill")
                                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent).padding(.horizontal)

                        LazyVStack(spacing: 0) {
                            ForEach(detail.chapters) { ch in
                                Button { openChapter(ch, defID: defID) } label: {
                                    HStack {
                                        if ch.id == lastChapterID { Image(systemName: "bookmark.fill").foregroundStyle(.tint) }
                                        Text(ch.title).foregroundStyle(ch.id == lastChapterID ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(theme.textColor))
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal).padding(.vertical, 12)
                                }
                                Divider().padding(.leading)
                            }
                        }
                    }.padding(.vertical)
                }
            } else if let detailError {
                ContentUnavailableView("加载失败", systemImage: "wifi.slash", description: Text(detailError))
            } else {
                ProgressView("加载漫画详情…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .appSurface(theme)
        .navigationTitle(item.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("查看原始网页", systemImage: "safari") { showInspect = true } }
        }
        .task {
            lastChapterID = ReadingHistory.find(in: context, url: item.pageURL.absoluteString, fileType: .comic)?.filePath
            do { comicDetail = try await session.extractComic(url: item.pageURL, definitionID: defID) }
            catch { if !Task.isCancelled { detailError = error.localizedDescription } }
        }
        .onDisappear { session.cancel() }
    }

    private func openChapter(_ ch: ComicChapter?, defID: String?) {
        guard let ch else { return }
        activeChapter = ch
        imageURLs = []; loading = true; loadError = nil
        Task {
            do { imageURLs = try await session.extractChapterImages(url: ch.chapterURL, definitionID: defID); loading = false }
            catch { if !Task.isCancelled { loadError = error.localizedDescription; loading = false } }
        }
    }

    private func comicChapterReader(chapter: ComicChapter, detail: ComicDetail, bookURL: URL, defID: String?) -> some View {
        let idx = detail.chapters.firstIndex(of: chapter) ?? 0
        return ZStack {
            Color.black.ignoresSafeArea()
            if loading { ProgressView("加载章节…").tint(.white) }
            else if let loadError { ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(loadError)).foregroundStyle(.white) }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(imageURLs, id: \.self) { url in
                            CoveImage(url: url, referer: chapter.chapterURL, definitionID: defID, contentMode: .fit)
                                .frame(minHeight: 280)
                        }
                    }
                }
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() } }
            }
            if showBars {
                VStack {
                    HStack {
                        Button { activeChapter = nil; saveComicProgress(detail: detail, bookURL: bookURL, defID: defID) } label: {
                            Image(systemName: "xmark").padding(10).glassEffect(.regular, in: Circle())
                        }
                        Text(chapter.title).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                    }.padding()
                    Spacer()
                    HStack(spacing: 24) {
                        Button { if idx > 0 { openChapter(detail.chapters[idx - 1], defID: defID) } } label: { Image(systemName: "chevron.left") }.disabled(idx <= 0)
                        Text("\(idx + 1) / \(detail.chapters.count)").font(.caption.monospacedDigit())
                        Button { if idx + 1 < detail.chapters.count { openChapter(detail.chapters[idx + 1], defID: defID) } } label: { Image(systemName: "chevron.right") }.disabled(idx + 1 >= detail.chapters.count)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 16)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onDisappear { saveComicProgress(detail: detail, bookURL: bookURL, defID: defID) }
    }

    private func saveComicProgress(detail: ComicDetail, bookURL: URL, defID: String?) {
        guard let ch = activeChapter, !detail.chapters.isEmpty else { return }
        let idx = detail.chapters.firstIndex(of: ch) ?? 0
        lastChapterID = ch.id
        ReadingHistory.recordProgress(
            in: context, title: detail.title, url: bookURL.absoluteString, filePath: ch.id, fileType: .comic,
            progress: Double(idx) / Double(detail.chapters.count),
            thumbnailURLString: detail.coverURL?.absoluteString, definitionID: defID,
            updateFilePath: true, updateMetadata: true
        )
    }

    // MARK: - 2. Local CBZ/CBR Vertical Reader

    private func cbzReaderBody(url: URL, history: ReadingHistory?) -> some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            if loading { ProgressView("解压漫画…") }
            else if let loadError { ContentUnavailableView("解压失败", systemImage: "xmark.circle", description: Text(loadError)) }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(imageURLs.enumerated()), id: \.offset) { idx, pageURL in
                                CoveImage(url: pageURL, contentMode: .fit)
                                    .frame(minHeight: 300).id(idx)
                                    .onAppear { currentPage = idx }
                            }
                        }
                    }
                    .onTapGesture { withAnimation { showBars.toggle() } }
                    .onChange(of: jumpPage) { _, target in
                        if let target { proxy.scrollTo(target, anchor: .top); jumpPage = nil }
                    }
                    .onAppear {
                        if let p = history?.progress, !imageURLs.isEmpty {
                            let target = ReadingHistory.restoredIndex(progress: p, count: imageURLs.count)
                            if target > 0 { currentPage = target; proxy.scrollTo(target, anchor: .top) }
                        }
                    }
                }
                if showBars && !imageURLs.isEmpty {
                    VStack {
                        ReaderGlassTopBar(title: url.deletingPathExtension().lastPathComponent, trailing: "\(currentPage + 1) / \(imageURLs.count)") { dismiss() }
                        Spacer()
                        if imageURLs.count > 1 {
                            Slider(value: Binding(get: { Double(currentPage) }, set: { currentPage = Int($0); jumpPage = Int($0) }),
                                   in: 0...Double(imageURLs.count - 1), step: 1)
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .glassEffect(.regular, in: Capsule())
                                .padding(.horizontal, 20).padding(.bottom, 16)
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await extractCBZ(url: url) }
        .onDisappear {
            if !imageURLs.isEmpty {
                ReadingHistory.recordProgress(
                    in: context, historyItem: history, title: url.deletingPathExtension().lastPathComponent,
                    filePath: url.path, fileType: url.pathExtension.lowercased() == "cbr" ? .cbr : .cbz,
                    progress: Double(currentPage + 1) / Double(imageURLs.count)
                )
            }
            if let dir = extractedDir { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) } }
        }
    }

    private func extractCBZ(url: URL) async {
        loading = true; loadError = nil
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("cbz-\(UUID().uuidString)", isDirectory: true)
        do {
            let urls = try await Task.detached(priority: .userInitiated) {
                try ReaderArchive.extract(archiveURL: url, to: dest) { entry in
                    ["jpg", "jpeg", "png", "webp", "gif"].contains((entry.path as NSString).pathExtension.lowercased())
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }.value
            extractedDir = dest; imageURLs = urls; loading = false
        } catch {
            loadError = error.localizedDescription; loading = false
        }
    }

    // MARK: - 3. NAS Image Pager (Zoom + Sibling Swipe)

    private func nasImageBody(entries: [NASFileEntry]) -> some View {
        let urls = entries.compactMap { CoveImagePipeline.smbURL(clientID: nasClientID, path: $0.path) }
        return ZStack {
            Color.black.ignoresSafeArea()
            if urls.indices.contains(currentPage) {
                CoveImage(url: urls[currentPage], contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .gesture(MagnifyGesture().onChanged { zoomScale = max(1, min(5, $0.magnification)) }
                        .onEnded { if $0.magnification < 1.1 { withAnimation { zoomScale = 1 } } })
                    .onTapGesture(count: 2) { withAnimation { zoomScale = zoomScale > 1.2 ? 1 : 2.5 } }
            }
            if entries.count > 1 && zoomScale <= 1.1 {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { if currentPage > 0 { currentPage -= 1 } }
                    Color.clear.contentShape(Rectangle()).onTapGesture { if currentPage + 1 < entries.count { currentPage += 1 } }
                }
            }
            VStack {
                ReaderGlassTopBar(title: entries.indices.contains(currentPage) ? entries[currentPage].name : "",
                                  trailing: entries.count > 1 ? "\(currentPage + 1)/\(entries.count)" : "") { dismiss() }
                Spacer()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { if case .nasImages(_, let idx, _) = source { currentPage = idx } }
    }

    private var nasClientID: String {
        if case .nasImages(_, _, let cid) = source { return cid }
        return ""
    }
}

private struct ReaderGlassTopBar: View {
    let title: String
    let trailing: String
    let onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    .frame(width: 36, height: 36).glassEffect(.regular, in: Circle())
            }
            Spacer()
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(1)
            Spacer()
            if !trailing.isEmpty {
                Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6).glassEffect(.regular, in: Capsule())
            }
        }
        .padding(.horizontal).padding(.top, 8)
    }
}
