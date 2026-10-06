import Foundation
import Network

struct FixtureResponse: Sendable {
    var status = 200
    var mime = "text/html; charset=utf-8"
    var body: Data
    var declaredLength: Int?
}

final class FixtureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cove.test.http")
    private let listener: NWListener
    private let routes: [String: FixtureResponse]
    private var connections: [NWConnection] = []
    init(routes: [String: FixtureResponse]) throws {
        self.routes = routes
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let ticket = FixtureReadyTicket(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    ticket.finish(.success( URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!))
                case .failed(let error): ticket.finish(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = bytes
            if let data { buffer.append(data) }
            guard buffer.count <= 16_384 else { connection.cancel(); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, bytes: buffer) }
                return
            }
            let rawPath = text.components(separatedBy: " ").dropFirst().first ?? "/"
            let path = rawPath.components(separatedBy: "?").first ?? "/"
            let response = self.routes[path] ?? FixtureResponse(status: 404, body: Data("missing".utf8))
            var status = response.status, body = response.body, rangeHeader = ""
            let ranges = response.mime.hasPrefix("video/") || response.mime.hasPrefix("audio/")
            if ranges, let header = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }),
               let value = header.split(separator: "=").last {
                let parts = value.split(separator: "-", omittingEmptySubsequences: false)
                let start = Int(parts.first ?? "") ?? 0
                let end = min(Int(parts.last ?? "") ?? (body.count - 1), body.count - 1)
                if start >= 0, start <= end, start < body.count {
                    rangeHeader = "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
                    body = body.subdata(in: start..<(end + 1)); status = 206
                } else { rangeHeader = "Content-Range: bytes */\(body.count)\r\n"; status = 416; body = Data() }
            }
            let rangeSupport = ranges ? "Accept-Ranges: bytes\r\n" : ""
            let header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(response.mime)\r\nContent-Length: \(response.declaredLength ?? body.count)\r\n" + rangeSupport + rangeHeader + "Connection: close\r\n\r\n"
            var output = Data(header.utf8)
            if !text.hasPrefix("HEAD ") { output.append(body) }
            connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { queue.async { self.listener.cancel(); self.connections.forEach { $0.cancel() }; self.connections.removeAll() } }
}

private final class FixtureReadyTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func finish(_ result: Result<URL, Error>) {
        let current = lock.withLock { let value = continuation; continuation = nil; return value }
        current?.resume(with: result)
    }
}
