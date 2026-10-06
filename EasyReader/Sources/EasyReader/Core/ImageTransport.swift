import Foundation

protocol ImageTransport: Sendable {
    func data(for request: ImageRequest) async throws -> Data
}

struct HTTPImageTransport: ImageTransport {
    func data(for request: ImageRequest) async throws -> Data {
        var urlRequest = URLRequest(url: request.url); urlRequest.timeoutInterval = 20
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let file = try await BoundedDownloader.download(urlRequest, maxBytes: 20 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }
}
