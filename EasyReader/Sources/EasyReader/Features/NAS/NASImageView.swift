import SwiftUI

/// Full-screen image viewer with prev/next navigation for NAS files.
struct NASImageView: View {
    // Sibling navigation
    var files: [NASFileEntry] = []
    var initialIndex: Int = 0
    var client: SMBClient?

    // Pre-loaded data (for the initial image opened from NASBrowserView)
    var initialData: Data?

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var imageData: Data?
    @State private var isLoadingImage = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image content
            if let data = imageData, let uiImage = UIImage(data: data) {
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
        .onAppear {
            currentIndex = initialIndex
            if let data = initialData {
                imageData = data
            } else {
                loadImage(at: initialIndex)
            }
        }
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
        guard index >= 0, index < files.count else { return }
        let entry = files[index]
        isLoadingImage = true
        imageData = nil

        // SMB: read file
        guard let client else { isLoadingImage = false; return }
        Task {
            let data = try? await client.readFile(at: entry.path)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.15)) {
                    imageData = data
                }
                isLoadingImage = false
            }
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

/// Legacy single-data image viewer (still used by NASBrowserView for in-memory data).
struct NASImageDataView: View {
    let data: Data

    var body: some View {
        NASImageView(initialData: data)
    }
}
