import SwiftUI
import AVKit
import AVFoundation
import SwiftData

/// 视频详情页：后台提取视频流 URL，直接原生播放；失败则回退 WebView。
struct VideoDetailView: View {
    let item: ParsedItem
    let definitionID: String?

    @State private var extractor       = VideoURLExtractor()
    @State private var player          : AVPlayer?
    @State private var currentPageURL  : URL
    @State private var savedProgress   : Double = 0
    @State private var showDiagnostic  = false
    @State private var dragOffset      : CGFloat = 0
    @State private var isAdvancingEpisode = false
    // Pre-populate from L0 synchronous cache — no blank frame when re-entering
    @State private var thumbImage      : UIImage?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    init(item: ParsedItem, definitionID: String? = nil) {
        self.definitionID = definitionID ?? SiteParserRegistry.definition(for: item.pageURL)?.id
        self.item = item
        _currentPageURL = State(initialValue: item.pageURL)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Fixed black background — stays put during drag
            Color.black.ignoresSafeArea()

            // Draggable content layer
            ZStack(alignment: .topLeading) {
                // Hidden rendering surface
                HiddenWebView(webView: extractor.webView)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)

                // Content
                switch extractor.state {
                case .loading:
                    loadingOverlay.transition(.opacity)

                case .found(let result):
                    NativeVideoPlayer(
                        url: result.streamURL,
                        headers: result.headers,
                        startTime: savedProgress,
                        player: $player,
                        onPlaybackEnded: { playNextEpisode(from: result) }
                    )
                        .id(currentPageURL)
                        .ignoresSafeArea()
                        .overlay(alignment: .topTrailing) {
                            if let player {
                                VideoNetworkSpeedBadge(player: player)
                                    .padding(.top, 54)
                                    .padding(.trailing, 16)
                            }
                        }
                        .transition(.opacity)

                case .notFound:
                    WebReaderView(url: currentPageURL)
                        .transition(.opacity)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                extractor.retry()
                            } label: {
                                Label("重试解析", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(.blue.opacity(0.9), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .padding(.trailing, 16)
                            .padding(.top, 52)
                        }
                }

                // Diagnostic overlay (notFound only) — bottom-right floating button
                if case .notFound = extractor.state, extractor.diagnostic != nil {
                    diagnosticBadge
                }

            }
            .offset(y: dragOffset)
            .scaleEffect(1 - min(dragOffset / 2000, 0.06), anchor: .top)
            .clipShape(RoundedRectangle(cornerRadius: dragOffset > 0 ? min(dragOffset / 5, 24) : 0))
        }
        .simultaneousGesture(dragToDismissGesture)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .background(SwipeBackEnabler())
        .onAppear {
            guard player == nil else { return }
            // Restore saved progress before starting extraction (must run first for cache hits)
            let urlString = currentPageURL.absoluteString
            let descriptor = FetchDescriptor<ReadingHistory>(
                predicate: #Predicate { $0.url == urlString }
            )
            if let entry = try? modelContext.fetch(descriptor).first, entry.progress > 2 {
                savedProgress = entry.progress
            }
            // Always (re)load — handles both first open and retry after previous failure
            extractor.load(url: currentPageURL, definitionID: definitionID)
        }
        .onAppear {
            // L0 synchronous read — instant if thumbnail was already cached this session
            if let url = item.thumbnail {
                thumbImage = ImageMemoryCache.shared.image(for: url)
            }
        }
        .task(id: item.thumbnail) {
            guard let url = item.thumbnail else { return }
            if thumbImage != nil { return }   // already got it from L0
            if let data = await ThumbnailCache.shared.data(for: url) {
                thumbImage = UIImage(data: data)
            }
        }
        .onChange(of: extractor.state) { _, state in
            if case .found(let result) = state {
                isAdvancingEpisode = false
                saveHistory(result: result)
            } else if case .notFound = state {
                isAdvancingEpisode = false
            }
        }
        .onDisappear {
            player?.pause()
            saveProgress()
        }
    }

    // MARK: - Diagnostic badge

    private var diagnosticBadge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    showDiagnostic = true
                } label: {
                    Label("诊断", systemImage: "stethoscope")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 52)
            }
        }
        .sheet(isPresented: $showDiagnostic) {
            DiagnosticSheet(info: extractor.diagnostic ?? "", pageURL: currentPageURL)
        }
    }

    // MARK: - Episode navigation

    private func playNextEpisode(from result: VideoResult) {
        guard !isAdvancingEpisode, let nextURL = result.nextPageURL else { return }
        playEpisode(at: nextURL)
    }

    private func playEpisode(at url: URL) {
        isAdvancingEpisode = true
        saveProgress()
        player?.pause()
        player = nil
        savedProgress = 0
        currentPageURL = url
        extractor.load(url: url, forceRefresh: true, definitionID: definitionID)
    }

    // MARK: - History (upsert by URL to avoid duplicates)

    private func saveHistory(result: VideoResult) {
        let urlString = currentPageURL.absoluteString
        let thumbStr  = item.thumbnail?.absoluteString
        let title = result.episodeNumber.map {
            "\(result.title ?? item.title) · 第\($0)集"
        } ?? item.title

        // Fetch existing entry for this URL
        let descriptor = FetchDescriptor<ReadingHistory>(
            predicate: #Predicate { $0.url == urlString }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.definitionID = definitionID
            existing.title              = title
            existing.lastReadAt         = Date()
            existing.thumbnailURLString = thumbStr
        } else {
            let entry = ReadingHistory(
                title: title,
                url: urlString,
                fileType: .video,
                thumbnailURLString: thumbStr
            )
            entry.definitionID = definitionID
            modelContext.insert(entry)
        }
    }

    // MARK: - Loading overlay

    private var loadingOverlay: some View {
        ZStack {
            if let img = thumbImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 24)
                    .overlay(Color.black.opacity(0.6))
            } else {
                Color.black
            }

            VStack(spacing: 24) {
                ZStack(alignment: .bottomTrailing) {
                    if let img = thumbImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
                    }
                    if !item.duration.isEmpty {
                        Text(item.duration)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(isAdvancingEpisode ? "正在切换剧集…" : "解析视频地址中…")
                        .foregroundStyle(.white.opacity(0.85))
                        .font(.subheadline)
                }
                Text(item.title)
                    .foregroundStyle(.white)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 32)
                Button("取消") {
                    extractor.cancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 4)
            }
        }
    }


    // MARK: - Drag-to-dismiss gesture (loading + playback only)

    private var dragToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                guard extractor.state != .notFound else { return }
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                guard extractor.state != .notFound else { return }
                if value.translation.height > 150 || value.predictedEndTranslation.height > 400 {
                    saveProgress()
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = UIScreen.main.bounds.height
                    } completion: {
                        dismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Progress persistence

    private func saveProgress() {
        guard let p = player else { return }
        let seconds = p.currentTime().seconds
        guard seconds.isFinite, seconds > 1 else { return }
        let urlString = currentPageURL.absoluteString
        let descriptor = FetchDescriptor<ReadingHistory>(
            predicate: #Predicate { $0.url == urlString }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.progress = seconds
        }
    }
}

// MARK: - Re-enable swipe-back gesture when nav bar is hidden

struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        SwipeBackVC()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    private final class SwipeBackVC: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

// MARK: - Native AVPlayer

struct NativeVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    var headers: [String: String] = [:]
    var startTime: Double = 0
    @Binding var player: AVPlayer?
    let onPlaybackEnded: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackEnded: onPlaybackEnded)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let vc = AVPlayerViewController()
        let asset = headers.isEmpty
            ? AVURLAsset(url: url)
            : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let p  = AVPlayer(playerItem: item)
        vc.player = p
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = true
        context.coordinator.observeEnd(of: item)
        player = p
        if startTime > 2 {
            let t = CMTime(seconds: startTime, preferredTimescale: 1000)
            p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        p.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.onPlaybackEnded = onPlaybackEnded
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        vc.player?.pause()
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPlaybackEnded: @MainActor () -> Void

        init(onPlaybackEnded: @escaping @MainActor () -> Void) {
            self.onPlaybackEnded = onPlaybackEnded
        }

        func observeEnd(of item: AVPlayerItem) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playbackEnded),
                name: AVPlayerItem.didPlayToEndTimeNotification,
                object: item
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func playbackEnded() {
            onPlaybackEnded()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - Diagnostic sheet

private struct DiagnosticSheet: View {
    let info: String
    let pageURL: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Page URL
                    Group {
                        Text("视频页 URL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(pageURL.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Divider()

                    // Raw diagnostic JSON
                    Text("页面诊断结果").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(info.isEmpty ? "（无数据）" : info)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("提取失败诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
