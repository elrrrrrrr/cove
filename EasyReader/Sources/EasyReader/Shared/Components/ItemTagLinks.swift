import SwiftUI

struct ItemTagLinks: View {
    private let tags: [String]
    let font: Font
    let onTap: (String) -> Void

    init(text: String, font: Font, onTap: @escaping (String) -> Void) {
        var seen = Set<String>()
        tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        self.font = font; self.onTap = onTap
    }
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Button { onTap(tag) } label: {
                    Text(tag).font(font).foregroundColor(.accentColor).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
