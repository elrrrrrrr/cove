import SwiftUI

struct ComicReader: View {
    let item: ResourceItem
    let content: ComicContent
    let history: LibraryEntry
    @Environment(SourceStore.self) private var sources
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale
    @State private var document: ArchiveDocument?
    @State private var pages: [URL] = []
    @State private var current: Int?
    @State private var error: String?
    @State private var loading = true
    @State private var pixels = 1200
    var body: some View {
        Group {
            if !content.chapters.isEmpty {
                List {
                    Section {
                        if let author = content.author, !author.isEmpty { LabeledContent("作者", value: author) }
                        if let status = content.status, !status.isEmpty { LabeledContent("状态", value: status) }
                        if let description = content.description, !description.isEmpty { Text(description).font(.subheadline).foregroundStyle(.secondary) }
                        if let locator = history.resumeLocator {
                            NavigationLink("继续阅读") {
                                ReaderRouter(item: chapterItem(title: item.title, locator: locator))
                            }
                        }
                    }
                    Section("章节") {
                        ForEach(content.chapters) { chapter in
                            NavigationLink(chapter.title) {
                                ReaderRouter(item: chapterItem(title: chapter.title, locator: chapter.locator))
                            }
                        }
                    }
                }
            } else if let error { ContentUnavailableView("无法阅读漫画", systemImage: "book.closed", description: Text(error)) }
            else if loading { ProgressView("正在准备漫画…") }
            else {
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(pages.enumerated()), id: \.offset) { index, url in
                                ComicPage(request: request(url), id: index)
                                    .id(index)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollPosition(id: $current, anchor: .top)
                    .onAppear { pixels = Int(geometry.size.width * scale) }
                }.background(.black)
            }
        }
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .bottomBar) {
                if !pages.isEmpty { Text("\((current ?? 0) + 1) / \(pages.count)").font(.caption.monospacedDigit()) }
            }
        }
        .task {
            guard content.chapters.isEmpty else { loading = false; return }
            do {
                if let archive = content.localArchive {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let document = try ArchiveService.open(archive)
                        return (document, try ArchiveService.comicPages(document))
                    }.value
                    try Task.checkCancellation()
                    document = result.0; pages = result.1
                } else { pages = content.images.compactMap(URL.init(string:)) }
                if pages.isEmpty { throw CoveError.message("漫画没有可阅读的图片") }
                current = min(max(0, Int(history.position)), pages.count - 1)
                history.resumeLocator = item.locator
                loading = false
            } catch { self.error = error.localizedDescription; loading = false }
        }
        .task(id: current) {
            guard let current, !pages.isEmpty else { return }
            history.position = Double(current)
            history.progress = Double(current) / Double(max(1, pages.count - 1))
            for neighbor in [current - 1, current + 1] where pages.indices.contains(neighbor) {
                let prepared = await SourceWebSession.imageRequest(request(pages[neighbor]))
                _ = await ImagePipeline.shared.image(prepared)
                if Task.isCancelled { return }
            }
        }
        .onDisappear { do { try library.persist() } catch { library.error = error.localizedDescription } }
    }
    private func request(_ url: URL) -> ImageRequest {
        ImageRequest(url: url, sourceID: item.sourceID, sourceRevision: sources.revisions[item.sourceID] ?? "",
                     assetRevision: item.revision, pixels: pixels, headers: ["Referer": item.locator],
                     transform: sources.definition(id: item.sourceID)?.modules?.images)
    }
    private func chapterItem(title: String, locator: String) -> ResourceItem {
        ResourceItem(sourceID: item.sourceID, title: title, locator: locator, kind: .comic,
                     identity: item.identity ?? item.locator, thumbnail: content.cover ?? item.thumbnail)
    }
}

private struct ComicPage: View {
    let request: ImageRequest
    let id: Int
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 300) }
        }.task(id: request.key) {
            let prepared = await SourceWebSession.imageRequest(request)
            image = DecodedImageCache.shared.get(prepared.key)?.image
            if let decoded = await ImagePipeline.shared.image(prepared), !Task.isCancelled { image = decoded.image }
        }
    }
}
