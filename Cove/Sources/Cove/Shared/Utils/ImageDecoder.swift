import UIKit
import ImageIO

enum ImageSizing: Hashable, Sendable {
    case thumbnail(Int)
    case page(width: Int)

    var cacheSuffix: String {
        switch self {
        case .thumbnail(let pixels): "thumbnail-\(pixels)"
        case .page(let width): "page-\(width)"
        }
    }
    static func pixels(points: CGFloat, scale: CGFloat) -> Int {
        let requested = max(64, min(4096, Int(ceil(points * scale))))
        return ((requested + 63) / 64) * 64
    }
}

enum ImageDecoder {
    static let maximumPixels = 8_000_000

    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return dimensions(source) != nil
    }

    static func decode(_ data: Data, sizing: ImageSizing) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, sizing: sizing)
    }

    static func decode(file: URL, sizing: ImageSizing) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, sizing: sizing)
    }

    private static func dimensions(_ source: CGImageSource) -> (width: Double, height: Double)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return [5, 6, 7, 8].contains(orientation) ? (height.doubleValue, width.doubleValue) : (width.doubleValue, height.doubleValue)
    }

    private static func decode(_ source: CGImageSource, sizing: ImageSizing) -> UIImage? {
        guard !Task.isCancelled, let size = dimensions(source) else { return nil }
        let requested: Double
        switch sizing {
        case .thumbnail(let pixels): requested = Double(max(1, pixels)) / max(size.width, size.height)
        case .page(let width): requested = Double(max(1, width)) / size.width
        }
        let ratio = min(1, requested, sqrt(Double(maximumPixels) / (size.width * size.height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(floor(max(size.width, size.height) * ratio)))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), !Task.isCancelled else { return nil }
        return UIImage(cgImage: image)
    }

    static func cost(_ image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}
