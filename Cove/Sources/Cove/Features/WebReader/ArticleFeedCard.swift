import SwiftUI

/// Each post stays together; its images form the Bento mosaic.
struct ArticleFeedCard: View {
    let item: ParsedItem
    let definitionID: String?
    let layout: BrowserLayout
    private var compact: Bool { layout != .bento }
    let saved: Bool
    let open: () -> Void
    let save: () -> Void
    @State private var width: CGFloat = 320
    private var images: [ArticleBlock] { Array((item.article?.blocks ?? []).filter { $0.kind == .image }.prefix(4)) }
    private var paragraphs: [ArticleBlock] { (item.article?.blocks ?? []).filter { $0.kind == .paragraph || $0.kind == .heading } }
    private var quote: ArticleBlock? { item.article?.blocks.first { $0.kind == .quote } }
    private var author: String { item.article?.author.isEmpty == false ? item.article!.author : item.extra }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(author.isEmpty ? (item.pageURL.host ?? "图文") : author)
                                .font(.subheadline.weight(.semibold)).lineLimit(2)
                            if !item.duration.isEmpty { Text(item.duration).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    if let document = item.article, let first = paragraphs.first,
                       !String(first.text.characters).hasPrefix(document.title) {
                        Text(document.title).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if paragraphs.isEmpty {
                        Text(item.title).font(.body).lineLimit(compact ? 6 : 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(paragraphs.map { String($0.text.characters) }.joined(separator: "\n\n"))
                            .font(.body).lineSpacing(5).lineLimit(compact ? 8 : 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if layout != .list { media }
                    if let quote {
                        Text(String(quote.text.characters)).font(.subheadline).lineLimit(5)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("article-feed-open")
            HStack {
                Label(item.article == nil ? "阅读全文" : "图文", systemImage: "doc.text")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: save) {
                    Label(saved ? "已收藏" : "收藏", systemImage: saved ? "heart.fill" : "heart").font(.subheadline)
                }.foregroundColor(.accentColor).accessibilityIdentifier("article-feed-save")
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary, lineWidth: 0.5))
        .onGeometryChange(for: CGFloat.self) { max(180, $0.size.width - 32) } action: { width = $0 }
    }
    @ViewBuilder private var media: some View {
        if images.count == 1, let image = images.first, let url = image.url {
            ArticleImage(url: url, referer: item.pageURL, definitionID: definitionID, width: width,
                         aspectRatio: min(1.8, max(0.8, image.aspectRatio)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else if !images.isEmpty {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<((images.count + 1) / 2), id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < images.count, let url = images[index].url {
                                ArticleImage(url: url, referer: item.pageURL, definitionID: definitionID,
                                             width: (width - 6) / 2, aspectRatio: 1.25)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else { Color.clear.frame(width: (width - 6) / 2, height: 1) }
                        }
                    }
                }
            }
        } else if let thumbnail = item.thumbnail {
            ArticleImage(url: thumbnail, referer: item.pageURL, definitionID: definitionID, width: width, aspectRatio: 1.6)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}
