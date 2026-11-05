import Foundation
import Network

final class ArticleFixtureServer: @unchecked Sendable {
    let listener: NWListener
    let url: String
    init(routes: [String: (String, Data)], rangeRequests: Bool = false) throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, _, error in
                guard error == nil, let data, let request = String(data: data, encoding: .utf8),
                      let path = request.split(separator: " ").dropFirst().first.map(String.init) else { connection.cancel(); return }
                let response = routes[path] ?? routes[path.split(separator: "?").first.map(String.init) ?? path]
                let body = response?.1 ?? Data("Not found".utf8)
                if rangeRequests, response != nil,
                   let rangeLine = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }),
                   let range = rangeLine.components(separatedBy: "=").last {
                    let parts = range.split(separator: "-", omittingEmptySubsequences: false)
                    if parts.count == 2, let start = Int(parts[0]), start >= 0, start < body.count {
                        let end = min(Int(parts[1]) ?? body.count - 1, body.count - 1)
                        if end >= start {
                            let bytes = body.subdata(in: start..<(end + 1))
                            let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: \(response!.0)\r\nContent-Range: bytes \(start)-\(end)/\(body.count)\r\nAccept-Ranges: bytes\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                            connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
                            return
                        }
                    }
                }
                let header = "HTTP/1.1 \(response == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(response?.0 ?? "text/html")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            listener.cancel(); throw URLError(.cannotConnectToHost)
        }
        url = "http://127.0.0.1:\(port.rawValue)"
    }
    deinit { listener.cancel() }
}
