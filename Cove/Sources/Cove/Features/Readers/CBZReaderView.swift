import SwiftUI
import ZIPFoundation
import SwiftData

/// Reads CBZ (and CBR as zip) comic archives with vertical scroll reading.
struct CBZReaderView: View {
    let fileURL: URL
    var historyItem: ReadingHistory?

    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @Environment(\.modelContext) private var context
    @Environment(\.displayScale) private var scale
    @Environment(\.dismiss) private var dismiss

    @State private var extractedDirectory: URL?
    @State private var pixels = 1024
    @State private var pages: [URL] = []
    @State private var currentPage  = 0
    @State private var jumpTarget: Int?
    @State private var showBars     = true
    @State private var isLoading    = true
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.backgroundColor.ignoresSafeArea()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("解压中…")
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
                    Label("解压失败", systemImage: "xmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await extractPages() } }.buttonStyle(.borderedProminent)
                    Button("返回") { dismiss() }
                }
            } else {
                scrollView
            }

            if showBars && !isLoading && error == nil && !pages.isEmpty {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showBars)
        .task { await extractPages() }
        .onDisappear {
            saveProgress()
            if let directory = extractedDirectory {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
                extractedDirectory = nil
            }
        }
    }

    // MARK: - Vertical scroll view

    private var scrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, url in
                        CBZPageImage(url: url, pixels: pixels)
                            .id(idx)
                            .onAppear { currentPage = idx }
                    }
                }
            }
            .onGeometryChange(for: Int.self) { [scale] proxy in ImageSizing.pixels(points: proxy.size.width, scale: scale) } action: { pixels = $0 }
            .task(id: "\(currentPage)-\(pixels)-\(pages.count)") {
                let adjacent = [currentPage - 1, currentPage + 1].filter { pages.indices.contains($0) }.map { pages[$0] }
                let width = pixels
                await withTaskGroup(of: Void.self) { group in
                    for url in adjacent { group.addTask { _ = await ImagePipeline.shared.image(at: url, sizing: .page(width: width)) } }
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
            }
            .onChange(of: jumpTarget) { _, target in
                if let target {
                    proxy.scrollTo(target, anchor: .top)
                    jumpTarget = nil
                }
            }
            .onAppear {
                // Restore saved progress
                if let item = historyItem, !pages.isEmpty {
                    let target = ReadingHistory.restoredIndex(progress: item.progress, count: pages.count)
                    if target > 0 {
                        currentPage = target
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private var floatingBackButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.textColor)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.leading, 16)
        .padding(.top, 12)
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").imageScale(.large)
            }
            Spacer()
            Text(fileURL.deletingPathExtension().lastPathComponent)
                .font(.headline).lineLimit(1)
            Spacer()
            Text("\(currentPage + 1) / \(pages.count)")
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(theme.textColor)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if pages.count > 1 {
                Slider(value: Binding(
                    get: { Double(currentPage) },
                    set: { newVal in
                        let page = Int(newVal)
                        currentPage = page
                        jumpTarget = page
                    }
                ), in: 0...Double(pages.count - 1), step: 1)
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Extraction

    private func extractPages() async {
        isLoading = true; error = nil
        let file = fileURL
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let task = Task.detached(priority: .userInitiated) { () throws -> [URL] in
            let extracted = try ReaderArchive.extract(archiveURL: file, to: tempDir) { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext)
            }
            return extracted.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        do {
            let all = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: tempDir) }; return
            }
            if let previous = extractedDirectory { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: previous) } }
            extractedDirectory = tempDir
            pages = all; isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }

    private func saveProgress() {
        guard !pages.isEmpty else { return }
        let p = Double(currentPage + 1) / Double(pages.count)
        ReadingHistory.recordProgress(
            in: context,
            historyItem: historyItem,
            title: fileURL.deletingPathExtension().lastPathComponent,
            filePath: fileURL.path,
            fileType: fileURL.pathExtension.lowercased() == "cbr" ? .cbr : .cbz,
            progress: p
        )
    }
}

// MARK: - Page Image View

private struct CBZPageImage: View {
    let url: URL
    let pixels: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .task(id: "\(url.absoluteString)-\(pixels)") {
            let loaded = await ImagePipeline.shared.image(at: url, sizing: .page(width: pixels))
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .onDisappear { image = nil }
    }
}
