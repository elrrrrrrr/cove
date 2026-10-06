import SwiftUI
import WebKit

struct OriginalWebView: View {
    let url: URL
    var sourceID: String?
    var history: LibraryEntry?
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @State private var progress: Double = 0
    var body: some View {
        NavigationStack {
            WebPage(url: url, sourceID: sourceID, progress: $progress)
                .navigationTitle(url.host() ?? "原始网页").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
                }
        }
        .onDisappear {
            guard let history else { return }
            history.progress = progress
            do { try library.persist() } catch { library.error = error.localizedDescription }
        }
    }
}

private struct WebPage: UIViewRepresentable {
    let url: URL
    let sourceID: String?
    @Binding var progress: Double
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = SourceWebSession.store(id: sourceID)
        let view = WKWebView(frame: .zero, configuration: config)
        view.scrollView.delegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: WebPage
        init(_ parent: WebPage) { self.parent = parent }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let range = scrollView.contentSize.height - scrollView.bounds.height
            guard range > 0 else { return }
            parent.progress = min(1, max(0, scrollView.contentOffset.y / range))
        }
    }
}
