import SwiftUI
import UIKit

/// Renders a catalog item title as plain text or, when provided, an alpha-mask title image
/// tinted to match the foreground color (mirroring CSS `mask-image` + `currentColor`).
struct ItemTitleView: View {
    let title: String
    let titleImage: URL?
    let referer: URL?
    var definitionID: String?
    var font: Font
    var fontSize: CGFloat
    var lineLimit: Int? = 2
    var foregroundColor: Color = .primary
    var alignment: Alignment = .leading

    private let request: ThumbnailRequest?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var availableWidth: CGFloat = 0

    init(
        title: String,
        titleImage: URL?,
        referer: URL? = nil,
        definitionID: String? = nil,
        font: Font,
        fontSize: CGFloat,
        lineLimit: Int? = 2,
        foregroundColor: Color = .primary,
        alignment: Alignment = .leading
    ) {
        self.title = title
        self.titleImage = titleImage
        self.referer = referer
        self.definitionID = definitionID
        self.font = font
        self.fontSize = fontSize
        self.lineLimit = lineLimit
        self.foregroundColor = foregroundColor
        self.alignment = alignment
        let req = titleImage.map {
            ThumbnailRequest(url: $0, referer: referer, definitionID: definitionID, sizing: .thumbnail(2048))
        }
        request = req
        _image = State(initialValue: req.flatMap { ImageMemoryCache.shared.image(for: $0) })
    }

    private var imageHeight: CGFloat { ceil(fontSize * 1.375) }

    var body: some View {
        if let request {
            Group {
                if let image {
                    renderedTitleImage(image)
                } else if failed {
                    fallbackText
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(foregroundColor.opacity(0.12))
                        .frame(maxWidth: .infinity, maxHeight: max(10, floor(fontSize * 0.85)))
                        .frame(height: imageHeight, alignment: .center)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                }
            }
            .task(id: request) {
                if let cached = ImageMemoryCache.shared.image(for: request) {
                    image = cached
                    failed = false
                    return
                }
                image = nil
                failed = false
                let loaded = await ImagePipeline.shared.image(for: request)
                guard !Task.isCancelled else { return }
                if let loaded {
                    withAnimation(.easeIn(duration: 0.12)) { image = loaded }
                } else {
                    failed = true
                }
            }
        } else {
            fallbackText
        }
    }

    @ViewBuilder
    private func renderedTitleImage(_ image: UIImage) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let naturalWidth = imageHeight * aspect
        let overflows = availableWidth > 0 && naturalWidth > availableWidth + 1
        let effectiveAlignment: Alignment = overflows ? .leading : alignment

        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
            .overlay(alignment: effectiveAlignment) {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(foregroundColor)
                    .frame(width: naturalWidth, height: imageHeight)
            }
            .mask {
                if overflows {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: min(16, availableWidth * 0.12))
                    }
                } else {
                    Color.black
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    private var fallbackText: some View {
        Text(title)
            .font(font)
            .lineLimit(lineLimit)
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
    }
}
