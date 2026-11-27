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
                    CachedThumbnail(url: item.thumbnail, placeholder: "photo.on.rectangle.angled", referer: item.pageURL, definitionID: definitionID)
                    if isFavorited { CardFavoriteBadge() }
                }
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                actionArea {
                    ItemTitleView(
                        title: item.title,
                        titleImage: item.titleImage,
                        referer: item.pageURL,
                        definitionID: definitionID,
                        font: .system(size: 13, weight: .medium),
                        fontSize: 13,
                        lineLimit: 2
                    )
                }
                if !item.extra.isEmpty {
                    CardExtraText(extra: item.extra, tags: item.extraTags, font: .system(size: 11), onTap: onExtraTap)
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

struct CardFavoriteBadge: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.pink)
            .padding(4)
            .background(.black.opacity(0.45), in: Circle())
            .padding(6)
    }
}

struct CardExtraText: View {
    let extra: String
    let tags: [String]
    let font: Font
    var onTap: ((String) -> Void)?

    var body: some View {
        if let onTap {
            ItemTagLinks(tags: tags, font: font, onTap: onTap)
        } else {
            Text(extra)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
