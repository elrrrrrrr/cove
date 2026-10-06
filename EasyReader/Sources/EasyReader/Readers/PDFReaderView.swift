import SwiftUI
import PDFKit

private struct LoadedPDF: @unchecked Sendable { let document: PDFDocument }

struct PDFReaderView: View {
    let fileURL: URL
    var title: String?
    var historyItem: LibraryEntry?
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: LoadedPDF?
    @State private var page = 0
    @State private var total = 0
    @State private var showBars = true
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let loaded {
                PDFSurface(document: loaded.document, page: $page) { showBars.toggle() }.ignoresSafeArea()
                if showBars {
                    VStack {
                        HStack {
                            Button("关闭", systemImage: "chevron.left") { dismiss() }.labelStyle(.iconOnly)
                            Spacer()
                            Text(title ?? fileURL.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Spacer()
                            Text("\(page + 1) / \(total)").font(.caption.monospacedDigit())
                        }.padding().background(.regularMaterial)
                        Spacer()
                        Slider(value: Binding(get: { Double(page) }, set: { page = Int($0) }), in: 0...Double(max(1, total - 1)), step: 1)
                            .disabled(total <= 1).padding().background(.regularMaterial)
                    }
                }
            } else if let error { ContentUnavailableView("无法打开 PDF", systemImage: "doc", description: Text(error)) }
            else { ProgressView("正在打开 PDF…") }
        }
        .navigationBarHidden(true)
        .task {
            let file = fileURL
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    guard let document = PDFDocument(url: file), document.pageCount > 0 else { throw CoveError.message("PDF 文件无效或需要密码") }
                    return LoadedPDF(document: document)
                }.value
                try Task.checkCancellation()
                total = result.document.pageCount
                page = min(max(0, Int(historyItem?.position ?? 0)), total - 1)
                loaded = result
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear {
            guard let entry = historyItem, total > 0 else { return }
            entry.position = Double(page)
            entry.progress = Double(page) / Double(max(1, total - 1))
            do { try library.persist() } catch { library.error = error.localizedDescription }
        }
    }
}

private struct PDFSurface: UIViewRepresentable {
    let document: PDFDocument
    @Binding var page: Int
    var onTap: () -> Void
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        if let target = document.page(at: page) { view.go(to: target) }
        context.coordinator.view = view
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed), name: .PDFViewPageChanged, object: view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if let current = view.currentPage, document.index(for: current) != page, let target = document.page(at: page) {
            view.go(to: target)
        }
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        view.document = nil
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: PDFSurface
        weak var view: PDFView?
        init(_ parent: PDFSurface) { self.parent = parent }
        @objc func tap() { parent.onTap() }
        @objc func changed() {
            guard let current = view?.currentPage else { return }
            parent.page = parent.document.index(for: current)
        }
    }
}
