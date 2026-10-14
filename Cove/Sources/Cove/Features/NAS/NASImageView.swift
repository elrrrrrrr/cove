import SwiftUI

/// Full-screen image viewer with prev/next navigation for NAS files.
struct NASImageView: View {
    // Sibling navigation
    var files: [NASFileEntry] = []
    var initialIndex: Int = 0
    var client: SMBClient?

    // Pre-loaded data (for the initial image opened from NASBrowserView)
    var initialData: Data?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var image: UIImage?
    @State private var pixels = 2048
    @State private var loadTask: Task<Void, Never>?
    @State private var loadID = UUID()
    @State private var isLoadingImage = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image content
            if let uiImage = image {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnifyGesture)
                    .gesture(panGesture)
                    .transition(.opacity)
            } else if isLoadingImage {
                ProgressView().tint(.white)
            } else {
                ContentUnavailableView("无法加载图片", systemImage: "photo")
                    .foregroundStyle(.white)
            }

            // Navigation tap zones (only when not zoomed)
            if files.count > 1, scale <= 1.1 {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { navigateImage(offset: -1) }
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { navigateImage(offset: 1) }
                }
            }

            // Counter badge
            if files.count > 1 {
                VStack {
                    Spacer()
                    Text("\(currentIndex + 1) / \(files.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .padding()
        }
        .onTapGesture(count: 2) {
            withAnimation {
                if scale > 1 { scale = 1; offset = .zero }
                else { scale = 2.5 }
            }
        }
        .onGeometryChange(for: Int.self) { [displayScale] proxy in
            ImageSizing.pixels(points: proxy.size.width * 2, scale: displayScale)
        } action: { pixels = $0 }
        .onAppear { currentIndex = initialIndex; loadImage(at: initialIndex) }
        .onChange(of: pixels) { loadImage(at: currentIndex) }
        .onDisappear { loadTask?.cancel() }
    }

    // MARK: - Navigation

    private func navigateImage(offset: Int) {
        let newIndex = currentIndex + offset
        guard newIndex >= 0, newIndex < files.count else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            scale = 1
            self.offset = .zero
        }
        currentIndex = newIndex
        loadImage(at: newIndex)
    }

    private func loadImage(at index: Int) {
        loadTask?.cancel()
        let id = UUID(); loadID = id
        let width = pixels
        let preloaded = index == initialIndex ? initialData : nil
        let entry = files.indices.contains(index) ? files[index] : nil
        isLoadingImage = true; image = nil
        loadTask = Task {
            let data: Data?
            if let preloaded { data = preloaded }
            else if let entry, let client { data = try? await client.readFile(at: entry.path) }
            else { data = nil }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { data.flatMap { ImageDecoder.decode($0, sizing: .page(width: width)) } }
            let decoded = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, loadID == id else { return }
            withAnimation(.easeIn(duration: 0.15)) { image = decoded }
            isLoadingImage = false; loadTask = nil
        }
    }

    // MARK: - Gestures

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = max(1, v.magnification) }
            .onEnded { _ in
                if scale < 1.1 { withAnimation { scale = 1; offset = .zero } }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                if scale > 1 { offset = v.translation }
            }
            .onEnded { _ in
                if scale <= 1.1 { withAnimation { offset = .zero } }
            }
    }
}

/// Image presentation for an already downloaded, bounded resource.
struct NASImageDataView: View {
    let data: Data

    var body: some View {
        NASImageView(initialData: data)
    }
}
