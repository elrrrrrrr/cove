import SwiftUI

/// Portrait cover card for comic items in SiteGalleryView.
struct ComicCard: View {
    let item: ParsedItem
    var isFavorited: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover (portrait 2:3)
            ZStack(alignment: .topTrailing) {
                if item.thumbnail != nil {
                    CachedThumbnail(url: item.thumbnail, placeholder: "photo.on.rectangle.angled")
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

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if !item.extra.isEmpty {
                    Text(item.extra)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 5)
        }
    }
}
