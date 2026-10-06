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
    @State private var showBars    = true
    @State private var pdfDocument: PDFDocument?

    var body: some View {
        ZStack(alignment: .bottom) {
            PDFViewRepresentable(
                url: fileURL,
                onPageChange: { current, total in
                    currentPage = current
                    totalPages  = total
                },
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showBars.toggle() }
                }
            )
            .ignoresSafeArea()

            if showBars {
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
        .onDisappear { saveProgress() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").imageScale(.large)
            }
            Spacer()
            Text(fileURL.deletingPathExtension().lastPathComponent)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(currentPage) / \(totalPages)")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if totalPages > 0 {
                Slider(
                    value: Binding(
                        get: { Double(currentPage) },
                        set: { _ in }   // PDFViewRepresentable handles page jumping
                    ),
                    in: 1...Double(max(totalPages, 1)),
                    step: 1
                )
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func saveProgress() {
        let progress = totalPages > 0 ? Double(currentPage) / Double(totalPages) : 0
        if let item = historyItem {
            item.progress   = progress
            item.lastReadAt = Date()
        } else {
            let entry = ReadingHistory(
                title: fileURL.deletingPathExtension().lastPathComponent,
                filePath: fileURL.path,
                fileType: .pdf,
                progress: progress
            )
            context.insert(entry)
        }
    }
}

// MARK: - UIViewRepresentable

struct PDFViewRepresentable: UIViewRepresentable {
    let url: URL
    var onPageChange: (Int, Int) -> Void = { _, _ in }
    var onTap: () -> Void = {}

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales     = true
        pdfView.displayMode    = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)

        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
            onPageChange(1, doc.pageCount)
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

    func updateUIView(_ uiView: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
