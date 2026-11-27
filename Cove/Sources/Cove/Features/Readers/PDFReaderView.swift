import SwiftUI
import PDFKit
import SwiftData

struct PDFReaderView: View {
    let fileURL: URL
    var historyItem: ReadingHistory?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage = 0
    @State private var totalPages  = 0
    @State private var jumpToPage: Int?
    @State private var loadFailed  = false
    @State private var showBars    = true

    var body: some View {
        ZStack(alignment: .bottom) {
            if loadFailed {
                ReaderErrorView(title: "无法打开 PDF", systemImage: "doc.richtext") { dismiss() }
            } else {
                PDFViewRepresentable(
                    url: fileURL,
                    initialProgress: historyItem?.progress,
                    jumpToPage: $jumpToPage,
                    onPageChange: { current, total in
                        currentPage = current
                        totalPages  = total
                    },
                    onLoadFailed: { loadFailed = true },
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                    }
                )
                .ignoresSafeArea()
            }

            if showBars && !loadFailed && totalPages > 0 {
                VStack(spacing: 0) {
                    ReaderTopBar(title: fileURL.deletingPathExtension().lastPathComponent, onBack: { dismiss() }) {
                        Text("\(currentPage) / \(totalPages)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ReaderPageSliderBar(current: currentPage, total: totalPages, oneBased: true) { page in
                        currentPage = page
                        jumpToPage = page
                    }
                }
                .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showBars)
        .onDisappear { saveProgress() }
    }

    private func saveProgress() {
        guard totalPages > 0 else { return }
        let progress = Double(currentPage) / Double(totalPages)
        ReadingHistory.recordProgress(
            in: context,
            historyItem: historyItem,
            title: fileURL.deletingPathExtension().lastPathComponent,
            filePath: fileURL.path,
            fileType: .pdf,
            progress: progress
        )
    }
}

// MARK: - UIViewRepresentable

struct PDFViewRepresentable: UIViewRepresentable {
    let url: URL
    var initialProgress: Double?
    @Binding var jumpToPage: Int?
    var onPageChange: (Int, Int) -> Void = { _, _ in }
    var onLoadFailed: () -> Void = {}
    var onTap: () -> Void = {}

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales     = true
        pdfView.displayMode    = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)

        if let doc = PDFDocument(url: url), doc.pageCount > 0 {
            pdfView.document = doc
            let targetIndex = initialProgress.map { ReadingHistory.restoredIndex(progress: $0, count: doc.pageCount) } ?? 0
            if targetIndex > 0, let page = doc.page(at: targetIndex) {
                pdfView.go(to: page)
            }
            let current = targetIndex + 1, total = doc.pageCount
            DispatchQueue.main.async { onPageChange(current, total) }
        } else {
            DispatchQueue.main.async { onLoadFailed() }
        }

        // Tap to toggle bars
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        pdfView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        context.coordinator.pdfView  = pdfView
        context.coordinator.parent   = self
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.parent = self
        if let target = jumpToPage, let doc = uiView.document,
           (1...doc.pageCount).contains(target), let page = doc.page(at: target - 1) {
            uiView.go(to: page)
            DispatchQueue.main.async { jumpToPage = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFViewRepresentable
        weak var pdfView: PDFView?

        init(_ parent: PDFViewRepresentable) { self.parent = parent }

        @objc func handleTap() { parent.onTap() }

        @objc func pageChanged() {
            guard let pdfView, let doc = pdfView.document,
                  let page = pdfView.currentPage else { return }
            let index = doc.index(for: page) + 1
            parent.onPageChange(index, doc.pageCount)
        }
    }
}
