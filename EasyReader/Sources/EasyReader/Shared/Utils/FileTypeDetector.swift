import Foundation

enum FileTypeDetector {
    static func detect(from url: URL) -> FileType {
        switch url.pathExtension.lowercased() {
        case "pdf":                                         return .pdf
        case "cbz", "zip":                                    return .cbz
        case "cbr", "rar":                                    return .cbr
        case "epub":                                        return .epub
        case "txt":                                         return .txt
        case "mp4", "mkv", "mov", "avi", "m4v", "ts",
             "wmv", "flv", "webm", "rmvb", "rm":           return .video
        case "mp3", "m4a", "flac", "aac", "ogg", "opus",
             "wav", "wma", "ape", "alac":                   return .audio
        case "jpg", "jpeg", "png", "gif", "webp",
             "bmp", "heic", "heif", "svg", "tiff", "tif":  return .image
        default:                                            return .unknown
        }
    }

    static func detect(fromPath path: String) -> FileType {
        detect(from: URL(fileURLWithPath: path))
    }
}
