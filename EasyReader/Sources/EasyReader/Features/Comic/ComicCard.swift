import SwiftUI

/// Portrait cover card for comic items in SiteGalleryView.
struct ComicCard: View {
    let item: ParsedItem
    var isFavorited: Bool = false
    var definitionID: String?
    var onTap: (() -> Void)?
    var onExtraTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover (portrait 2:3)
            actionArea {
                ZStack(alignment: .topTrailing) {
                    if item.thumbnail != nil {
                        CachedThumbnail(url: item.thumbnail, placeholder: "photo.on.rectangle.angled", referer: item.pageURL, definitionID: definitionID)
                    } else {
                        Color(.secondarySystemBackground)
                            .overlay {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2).foregroundStyle(.tertiary)
                            }
                    }
                    if isFavorited {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.pink)
                            .padding(4)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(6)
                    }
                }
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                actionArea {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
                if !item.extra.isEmpty {
                    if let onExtraTap {
                        ItemTagLinks(text: item.extra, font: .system(size: 11), onTap: onExtraTap)
                    } else {
                        Text(item.extra)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder private func actionArea<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let onTap { Button(action: onTap, label: content).buttonStyle(.plain) }
        else { content() }
    }
}
