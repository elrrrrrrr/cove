import SwiftUI

struct ResourceThumbnail: View {
    let item: ResourceItem
    @Environment(SourceStore.self) private var sources
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    @State private var targetPixels = 0
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: item.kind.icon).font(.title).foregroundStyle(.secondary) }
        }
        .clipped()
        .onGeometryChange(for: Int.self) { [scale] geometry in
            let dimension = max(geometry.size.width, geometry.size.height) * scale
            guard dimension.isFinite, dimension > 0 else { return 0 }
            return min(2400, max(128, Int(ceil(dimension / 64)) * 64))
        } action: { targetPixels = $0 }
        .task(id: item.id + item.revision + "\(targetPixels)" + (sources.revisions[item.sourceID] ?? "")) {
            guard targetPixels > 0 else { return }
            do {
                guard let definition = sources.definition(id: item.sourceID) else { return }
                var provider: (any SourceProvider)?
                if item.thumbnail == nil && definition.source.adapter != .web { provider = try sources.provider(id: item.sourceID) }
                defer { withExtendedLifetime(provider) {} }
                let url: URL?
                var rangeReader: (any RangeReader)?
                var remotePath: String?
                let video = item.kind == .video && item.thumbnail == nil
                if let thumbnail = item.thumbnail { url = URL(string: thumbnail) }
                else if [.image, .video].contains(item.kind), let local = provider as? FileSourceProvider { url = local.fileURL(item) }
                else if item.kind == .image, let smb = provider as? SMBSourceProvider, (item.byteSize ?? .max) <= 20 * 1024 * 1024 {
                    url = try await ResourceAccess.shared.localFile(for: item, client: smb.client, scope: sources.revisions[item.sourceID] ?? "")
                } else if item.kind == .video, let smb = provider as? SMBSourceProvider {
                    var components = URLComponents(); components.scheme = "cove-thumbnail"; components.host = "resource"; components.path = item.locator
                    url = components.url; rangeReader = smb.client; remotePath = item.locator
                } else { url = nil }
                guard let url else { image = nil; return }
                var headers = definition.source.adapter == .web ? ["Referer": item.locator] : [:]
                if definition.source.adapter == .web, let cookie = await SourceWebSession.cookieHeader(id: item.sourceID, url: url) { headers["Cookie"] = cookie }
                let request = ImageRequest(url: url, sourceID: item.sourceID,
                    sourceRevision: sources.revisions[item.sourceID] ?? "",
                    assetRevision: item.revision, pixels: targetPixels, video: video, rangeReader: rangeReader, remotePath: remotePath,
                    headers: headers,
                    transform: definition.modules?.images)
                image = DecodedImageCache.shared.get(request.key)?.image
                if let loaded = await ImagePipeline.shared.image(request), !Task.isCancelled { image = loaded.image }
            } catch { image = nil }
        }
    }
}

struct ResourceCard: View {
    let item: ResourceItem
    let favorite: Bool
    let read: Bool
    var layout: String
    var onOpen: () -> Void
    var onFavorite: () -> Void
    var onTag: ((String) -> Void)?
    var onEpisodes: (() -> Void)?
    var body: some View {
        if layout == "list" {
            HStack(spacing: 12) {
                Button(action: onOpen) { ResourceThumbnail(item: item).frame(width: 72, height: 60).clipShape(RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: onOpen) { Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2) }.buttonStyle(.plain)
                    metadata
                }
                Spacer(minLength: 0)
                favoriteButton
            }.padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Button(action: onOpen) {
                    Color(.secondarySystemBackground)
                        .aspectRatio(layout == "portrait" ? 0.7 : 16.0 / 9.0, contentMode: .fit)
                        .overlay { ResourceThumbnail(item: item) }
                        .overlay(alignment: .bottomTrailing) {
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle).font(.caption2).foregroundStyle(.white)
                                    .padding(4).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                HStack(alignment: .top, spacing: 4) {
                    Button(action: onOpen) { Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    favoriteButton
                }
                metadata
            }
        }
    }
    private var favoriteButton: some View {
        Button(action: onFavorite) { Image(systemName: favorite ? "heart.fill" : "heart").foregroundColor(favorite ? .red : .secondary).frame(width: 44, height: 44) }
            .buttonStyle(.plain).accessibilityLabel(favorite ? "取消收藏" : "收藏")
    }
    private var metadata: some View {
        HStack(spacing: 5) {
            if read { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
            if let onTag {
                ForEach(Array(item.tags.prefix(2)), id: \.self) { tag in
                    Button(tag) { onTag(tag) }.buttonStyle(.plain).foregroundColor(.accentColor).lineLimit(1)
                }
            } else { Text(item.kind.label).foregroundStyle(.secondary) }
            if let onEpisodes, let count = item.episodeCount { Button("选集(\(count))", action: onEpisodes).buttonStyle(.plain).foregroundColor(.accentColor) }
        }.font(.caption).frame(minHeight: 20)
    }
}
