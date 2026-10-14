import SwiftUI

/// Shared chapter/TOC sheet for document readers (TXT, EPUB, …).
/// Chrome (navigation title, done button, list style) is uniform; callers only
/// describe how a chapter looks and what selecting it does.
struct ChapterListSheet<Chapter: Identifiable>: View {
    let chapters: [Chapter]
    let title: (Chapter) -> String
    var subtitle: ((Chapter) -> String)? = nil
    var isCurrent: (Chapter) -> Bool = { _ in false }
    var doneTitle: String = "完成"
    let onSelect: (Chapter) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(chapters) { chapter in
                Button {
                    onSelect(chapter)
                    dismiss()
                } label: {
                    HStack {
                        Text(title(chapter)).lineLimit(2)
                        if let subtitle = subtitle?(chapter) {
                            Spacer()
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(isCurrent(chapter) ? Color.accentColor : .primary)
            }
            .appSurface()
            .navigationTitle("目录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(doneTitle) { dismiss() } }
            }
        }
    }
}
