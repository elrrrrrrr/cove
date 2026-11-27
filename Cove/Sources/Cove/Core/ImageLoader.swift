import SwiftUI
import Nuke
import NukeUI
import CryptoKit
import AVFoundation

// MARK: - Custom Nuke DataLoader (Referer + AES decrypt + Data URI + SMB)

enum CoveImagePipeline {
    static let definitionIDHeader = "X-Cove-Definition-ID"

    static let shared: Nuke.ImagePipeline = {
        var config = Nuke.ImagePipeline.Configuration()
        config.dataLoader = CoveDataLoader()
        return Nuke.ImagePipeline(configuration: config)
    }()

    static func smbURL(clientID: String, path: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "cove-smb"
        comps.host = clientID
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        return comps.url
    }

    static func clearCache() {
        shared.cache.removeAll()
    }
}

private final class CoveDataLoader: Nuke.DataLoading, @unchecked Sendable {
    private let httpLoader = Nuke.DataLoader()

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> Nuke.Cancellable {
        guard let url = request.url else {
            completion(URLError(.badURL))
            return BlockCancellable {}
        }

        // 1. data: URI
        if url.scheme?.lowercased() == "data" {
            if let data = Self.decodeDataURI(url.absoluteString) {
                let resp = URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil)
                didReceiveData(data, resp)
                completion(nil)
            } else {
                completion(URLError(.cannotDecodeContentData))
            }
            return BlockCancellable {}
        }

        // 2. cove-smb://<clientIdentity>?path=<remotePath>
        if url.scheme?.lowercased() == "cove-smb" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let remotePath = comps?.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
            let clientID = url.host() ?? ""
            let task = Task {
                do {
                    guard let client = await SMBClientRegistry.shared.client(for: clientID) else {
                        throw SMBError.notConnected
                    }
                    let data = try await Self.loadSMBImageData(client: client, path: remotePath)
                    try Task.checkCancellation()
                    let resp = URLResponse(url: url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil)
                    didReceiveData(data, resp)
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
            return BlockCancellable { task.cancel() }
        }

        // 3. HTTP / HTTPS (with optional SiteImageTransform AES decryption)
        var cleanRequest = request
        if cleanRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            cleanRequest.setValue(WebURLSafety.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if cleanRequest.value(forHTTPHeaderField: "Accept") == nil {
            cleanRequest.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        }
        let refererURL = cleanRequest.value(forHTTPHeaderField: "Referer").flatMap(URL.init(string:)) ?? url
        if cleanRequest.value(forHTTPHeaderField: "Referer") == nil {
            cleanRequest.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if cleanRequest.value(forHTTPHeaderField: "Origin") == nil,
           var origin = URLComponents(url: refererURL, resolvingAgainstBaseURL: true) {
            origin.path = ""; origin.query = nil; origin.fragment = nil; origin.user = nil; origin.password = nil
            if let originStr = origin.string {
                cleanRequest.setValue(originStr, forHTTPHeaderField: "Origin")
            }
        }
        let defID = cleanRequest.value(forHTTPHeaderField: CoveImagePipeline.definitionIDHeader)
        cleanRequest.setValue(nil, forHTTPHeaderField: CoveImagePipeline.definitionIDHeader)

        if let transform = SiteParserRegistry.imageTransform(for: url, referer: refererURL, definitionID: defID),
           let key = transform.key.data(using: .utf8),
           let iv = transform.iv.data(using: .utf8) {
            let box = DecryptBuffer()
            return httpLoader.loadData(with: cleanRequest) { chunk, response in
                box.append(chunk, response: response)
            } completion: { error in
                if let error { completion(error); return }
                let (encrypted, response) = box.take()
                let decoded: Data? = if Self.looksLikePlainImage(encrypted) {
                    encrypted
                } else {
                    SiteCrypto.decrypt(encrypted, key: key, iv: iv)
                        ?? Data(base64Encoded: String(data: encrypted, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                            .flatMap { SiteCrypto.decrypt($0, key: key, iv: iv) }
                }
                guard let decoded, let response else {
                    completion(URLError(.cannotDecodeContentData))
                    return
                }
                didReceiveData(decoded, response)
                completion(nil)
            }
        }

        return httpLoader.loadData(with: cleanRequest, didReceiveData: didReceiveData, completion: completion)
    }

    private static func looksLikePlainImage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return true } // JPEG
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true } // PNG
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true } // GIF
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return true } // WEBP
        if b.count >= 8, b[4...7] == [0x66, 0x74, 0x79, 0x70] { return true } // AVIF/HEIF
        return UIImage(data: data) != nil
    }

    private final class DecryptBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var response: URLResponse?
        func append(_ chunk: Data, response: URLResponse) {
            lock.withLock { data.append(chunk); self.response = response }
        }
        func take() -> (Data, URLResponse?) {
            lock.withLock { (data, response) }
        }
    }

    private static func decodeDataURI(_ raw: String) -> Data? {
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let meta = String(raw[..<comma]).lowercased()
        let body = String(raw[raw.index(after: comma)...])
        if meta.contains(";base64") {
            return Data(base64Encoded: body.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression))
        }
        return body.removingPercentEncoding?.data(using: .utf8)
    }

    private static func loadSMBImageData(client: SMBClient, path: String) async throws -> Data {
        if FileType.detect(fromPath: path) == .video {
            let asset = SMBStreamLoader.makeAsset(client: client, remotePath: path)
            defer { SMBStreamLoader.cancel(in: asset) }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            let cg = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 60)).image
            guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.78) else {
                throw URLError(.cannotDecodeContentData)
            }
            return data
        }
        return try await client.readFile(at: path)
    }

    private final class BlockCancellable: Nuke.Cancellable {
        let onCancel: @Sendable () -> Void
        init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }
}

// MARK: - Unified Async Image View

struct CoveImage: View {
    let url: URL?
    var referer: URL? = nil
    var definitionID: String? = nil
    var placeholder: String = "photo"
    var contentMode: ContentMode = .fill

    private var imageRequest: ImageRequest? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let definitionID { req.setValue(definitionID, forHTTPHeaderField: CoveImagePipeline.definitionIDHeader) }
        return ImageRequest(urlRequest: req)
    }

    var body: some View {
        if let imageRequest {
            LazyImage(request: imageRequest) { state in
                if let image = state.image {
                    if contentMode == .fill {
                        Color.clear
                            .overlay { image.resizable().scaledToFill() }
                            .clipped()
                    } else {
                        image.resizable().scaledToFit()
                    }
                } else {
                    placeholderView
                }
            }
            .pipeline(CoveImagePipeline.shared)
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        Color.secondary.opacity(0.14)
            .overlay {
                Image(systemName: placeholder)
                    .font(.title3)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
    }
}

// MARK: - Title Renderer (text or tinted alpha-mask title image)

struct ItemTitleView: View {
    let title: String
    var titleImage: URL? = nil
    var referer: URL? = nil
    var definitionID: String? = nil
    var font: Font = .subheadline.weight(.medium)
    var fontSize: CGFloat = 14
    var lineLimit: Int? = 2
    var foregroundColor: Color = .primary
    var alignment: Alignment = .leading

    @State private var availableWidth: CGFloat = 0

    private var imageHeight: CGFloat { ceil(fontSize * 1.375) }

    private var imageRequest: ImageRequest? {
        guard let titleImage else { return nil }
        var req = URLRequest(url: titleImage)
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let definitionID { req.setValue(definitionID, forHTTPHeaderField: CoveImagePipeline.definitionIDHeader) }
        return ImageRequest(urlRequest: req)
    }

    var body: some View {
        if let imageRequest {
            LazyImage(request: imageRequest) { state in
                if let uiImage = state.imageContainer?.image {
                    let aspect = uiImage.size.height > 0 ? uiImage.size.width / uiImage.size.height : 1
                    let naturalWidth = imageHeight * aspect
                    let overflows = availableWidth > 0 && naturalWidth > availableWidth + 1
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: imageHeight)
                        .overlay(alignment: overflows ? .leading : alignment) {
                            Image(uiImage: uiImage)
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
                            } else { Color.black }
                        }
                        .clipped()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                } else if state.error != nil {
                    fallbackText
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(foregroundColor.opacity(0.12))
                        .frame(maxWidth: .infinity, maxHeight: max(10, floor(fontSize * 0.85)))
                        .frame(height: imageHeight)
                }
            }
            .pipeline(CoveImagePipeline.shared)
        } else {
            fallbackText
        }
    }

    private var fallbackText: some View {
        Text(title)
            .font(font)
            .lineLimit(lineLimit)
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
    }
}
