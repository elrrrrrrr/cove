import SwiftUI
import UIKit

/// Preserve code punctuation instead of applying the keyboard's smart quotes/dashes.
struct CodeTextEditor: UIViewRepresentable {
    @Binding var text: String
    var label: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.backgroundColor = .secondarySystemBackground
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityLabel = label
        view.delegate = context.coordinator
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityLabel = label
        if view.text != text {
            let cursor = min(view.selectedRange.location, text.utf16.count)
            view.text = text
            view.selectedRange = NSRange(location: cursor, length: 0)
        }
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextEditor
        init(_ parent: CodeTextEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
