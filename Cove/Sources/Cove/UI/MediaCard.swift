import SwiftUI

// MARK: - Unified Catalog Media Card (Bento / Portrait / List)

struct MediaCard: View {
    enum Mode {
        case bento(BentoCardSize)
        case portrait
        case list
    }

    let item: ParsedItem
    let mode: Mode
    var isFavorited: Bool = false
    var definitionID: String? = nil
    var placeholder: String = "play.rectangle.fill"
    var onExtraTap: ((String) -> Void)? = nil
    let onTap: () -> Void

    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark

    var body: some View {
        Button(action: onTap) {
            switch mode {
            case .bento(let size): bentoBody(large: size == .large)
            case .portrait:        portraitBody
            case .list:            listBody
            }
        }
        .buttonStyle(SpringPressButtonStyle())
    }

    private func bentoBody(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            metaBlock(font: large ? .subheadline.weight(.semibold) : .caption.weight(.medium),
                      fontSize: large ? 15 : 13, lineLimit: large ? 2 : 1, extraSize: large ? 12 : 11)
        }
    }

    private var portraitBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbOverlay
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            metaBlock(font: .caption.weight(.medium), fontSize: 13, lineLimit: 2, extraSize: 11)
        }
    }

    private var listBody: some View {
        HStack(spacing: 12) {
            if item.thumbnail != nil {
                CoveImage(url: item.thumbnail, referer: item.pageURL, definitionID: definitionID, placeholder: placeholder)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                ItemTitleView(title: item.title, titleImage: item.titleImage, referer: item.pageURL,
                              definitionID: definitionID, font: .subheadline.weight(.medium),
                              fontSize: 15, lineLimit: 2, foregroundColor: theme.textColor)
                let meta = [item.extra, item.duration].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(theme.cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var thumbOverlay: some View {
        ZStack(alignment: .bottomTrailing) {
            CoveImage(url: item.thumbnail, referer: item.pageURL, definitionID: definitionID, placeholder: placeholder)
            if !item.duration.isEmpty {
                Text(item.duration)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(6)
            }
            if isFavorited {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.pink)
                    .padding(5)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private func metaBlock(font: Font, fontSize: CGFloat, lineLimit: Int, extraSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ItemTitleView(title: item.title, titleImage: item.titleImage, referer: item.pageURL,
                          definitionID: definitionID, font: font, fontSize: fontSize,
                          lineLimit: lineLimit, foregroundColor: theme.textColor)
            if !item.extra.isEmpty {
                if let onExtraTap, item.extraTags.count > 1 || item.extraTags.first == item.extra {
                    HStack(spacing: 4) {
                        ForEach(Array(item.extraTags.prefix(3).enumerated()), id: \.offset) { _, tag in
                            Button(tag) { onExtraTap(tag) }
                                .font(.system(size: extraSize))
                                .foregroundStyle(Color.accentColor)
                                .buttonStyle(.plain)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text(item.extra)
                        .font(.system(size: extraSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

// MARK: - Site Quick Access Squircle

struct SiteQuickTile: View {
    let site: BookmarkSite
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .cinemaDark

    private var iconColor: Color {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .mint, .red]
        let hash = site.name.utf8.reduce(UInt(5381)) { ($0 &<< 5) &+ $0 &+ UInt($1) }
        return palette[Int(hash % UInt(palette.count))]
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(iconColor.gradient)
                    .frame(width: 58, height: 58)
                Text(String(site.name.prefix(1)))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
            Text(site.name)
                .font(.caption)
                .foregroundStyle(theme.textColor)
                .lineLimit(1)
        }
    }
}
