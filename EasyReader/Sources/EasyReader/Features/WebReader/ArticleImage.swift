import SwiftUI

struct ArticleImage: View {
    let url: URL
    let referer: URL
    let definitionID: String?
    let width: CGFloat
    let aspectRatio: Double
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var failed = false
    private var request: ThumbnailRequest {
        ThumbnailRequest(url: url, referer: referer, definitionID: definitionID,
            sizing: .page(width: ImageSizing.pixels(points: width, scale: scale)))
    }
    var body: some View {
        let request = self.request
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Label("图片暂时无法加载", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(width: width, height: min(600, max(80, width / aspectRatio)))
        .task(id: request.cacheID) {
            image = nil; failed = false
            let value = await ImagePipeline.shared.image(for: request)
            guard !Task.isCancelled else { return }
            image = value; failed = value == nil
        }
        .onDisappear { image = nil }
    }
}
