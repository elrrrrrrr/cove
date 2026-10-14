import SwiftUI
// MARK: - Nav link card (for portal / navigation sites)

struct NavLinkCard: View {
    let item: ParsedItem
    var definitionID: String?

    private var hasThumbnail: Bool { item.thumbnail != nil }

    var body: some View {
        HStack(spacing: 14) {
            // Only show thumbnail area when one exists
            if hasThumbnail {
                CachedThumbnail(url: item.thumbnail, placeholder: "globe", referer: item.pageURL, definitionID: definitionID)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                // Metadata row: extra (author · date) + duration (upvotes, replies, etc.)
                let parts = [item.extra, item.duration].filter { !$0.isEmpty }
                if !parts.isEmpty {
                    Text(parts.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Video card (16:9 thumbnail + metadata)

struct VideoCard: View {
    let item: ParsedItem
    var isFavorited: Bool = false
    var cardSize: BentoCardSize = .small
    var definitionID: String?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var placeholder = "play.rectangle.fill"
    /// Called with the tapped tag string (e.g. actress name, category keyword).
    var onExtraTap: ((String) -> Void)?

    private var titleFont: Font {
        cardSize == .large
            ? .system(size: 15, weight: .semibold)
            : .system(size: 13, weight: .medium)
    }
    private var titleLines: Int { cardSize == .large ? 3 : 2 }
    private var extraFont: Font {
        cardSize == .large
            ? .system(size: 13)
            : .system(size: 11)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailView
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .gesture(cardGesture)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(titleFont)
                    .lineLimit(titleLines)
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                    .gesture(cardGesture)
                if !item.extra.isEmpty {
                    if onExtraTap != nil {
                        extraTagsView
                    } else {
                        Text(item.extra)
                            .font(extraFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .gesture(cardGesture)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .contentShape(Rectangle())
    }

    private var cardGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first(true): onLongPress?()
                case .second: onTap?()
                default: break
                }
            }
    }

    // MARK: - Extra tags

    private var extraTagsView: some View {
        ItemTagLinks(tags: item.extraTags, font: extraFont) { onExtraTap?($0) }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack(alignment: .bottomTrailing) {
            if item.thumbnail != nil {
                CachedThumbnail(url: item.thumbnail, placeholder: placeholder, referer: item.pageURL, definitionID: definitionID)
            } else {
                Color(.secondarySystemBackground)
                    .overlay {
                        Image(systemName: placeholder)
                            .font(.title).foregroundStyle(.tertiary)
                    }
            }
            if !item.duration.isEmpty {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            }
            if !item.duration.isEmpty {
                Text(item.duration)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .padding(6)
            }
            if isFavorited {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.pink)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
}

// MARK: - Thread image card (full-width image for forum thread galleries)

struct ThreadImageCard: View {
    let url: URL?
    private let source: ThumbnailRequest?
    @Environment(\.displayScale) private var scale
    @State private var pixels = 1024
    private var request: ThumbnailRequest? { source?.resized(.page(width: pixels)) }
    let index: Int

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, index: Int, referer: URL?, definitionID: String?) {
        self.url = url
        self.index = index
        source = url.map { ThumbnailRequest(url: $0, referer: referer, definitionID: definitionID, sizing: .page(width: 1024)) }
        _image = State(initialValue: source.flatMap { ImageMemoryCache.shared.image(for: $0) })
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("图片加载失败")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color(.secondarySystemBackground))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .onGeometryChange(for: Int.self) { [scale] proxy in ImageSizing.pixels(points: proxy.size.width, scale: scale) } action: { pixels = $0 }
        .task(id: request) {
            guard let request else { return }
            failed = false
            let loaded = await ImagePipeline.shared.image(for: request)
            guard !Task.isCancelled else { return }
            if let img = loaded {
                withAnimation(.easeIn(duration: 0.15)) {
                    image = img
                }
            } else {
                failed = true
            }
        }
        .onAppear {
            if image == nil, !failed, let request {
                image = ImageMemoryCache.shared.image(for: request)
            }
        }
        .onDisappear {
            image = nil
        }
    }
}

// MARK: - Card press style (scale-down feedback on tap)

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

