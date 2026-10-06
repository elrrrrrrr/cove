struct SitePortal: Codable, Sendable, Equatable {
    var url: String
    var base64Pattern: String?
    var dataPattern: String?
    var keyPattern: String?
    var urlPaths: [String]?
    var identityPaths: [String]?
    var identityPattern: String?
    var excludedHosts: [String]?
    var headers: [String: String]?
    func validate() throws {
        guard let value = URL(string: url), ["http", "https"].contains(value.scheme ?? ""), value.host() != nil else { throw CoveError.message("门户地址无效") }
        for pattern in [base64Pattern, dataPattern, keyPattern, identityPattern].compactMap({ $0 }) { _ = try NSRegularExpression(pattern: pattern) }
    }
}

struct SiteImageTransform: Codable, Sendable, Equatable {
    var hosts: [String]?
    var key: String
    var iv: String
    func validate() throws {
        guard [16, 24, 32].contains(key.utf8.count), iv.utf8.count == 16 else { throw CoveError.message("AES 密钥或 IV 长度无效") }
    }
}


import Foundation
import CommonCrypto
import CryptoKit

enum SiteCrypto {
    static func decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard [16, 24, 32].contains(key.count), iv.count == 16,
              !data.isEmpty, data.count % 16 == 0 else { return nil }
        var output = Data(count: data.count + 16)
        let capacity = output.count
        var length = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress, input.baseAddress, data.count,
                            out.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(length..<output.count)
        return output
    }
}

enum SitePortalResolver {
    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    static func values(at path: String, in object: Any) -> [String] {
        func visit(_ parts: ArraySlice<String>, _ value: Any) -> [String] {
            guard let head = parts.first else { return (value as? String).map { [$0] } ?? [] }
            if head == "*", let array = value as? [Any] { return array.flatMap { visit(parts.dropFirst(), $0) } }
            guard let dict = value as? [String: Any], let next = dict[head] else { return [] }
            return visit(parts.dropFirst(), next)
        }
        return visit(path.split(separator: ".").map(String.init)[...], object)
    }

    static func resolve(in html: String, portal: URL, target: URL, config: SitePortal) -> URL? {
        func rewrite(_ candidates: [String]) -> URL? {
            for candidate in candidates {
                guard let url = URL(string: candidate, relativeTo: portal)?.absoluteURL,
                      ["http", "https"].contains(url.scheme ?? ""),
                      let host = url.host(), host.lowercased() != portal.host()?.lowercased(),
                      !(config.excludedHosts ?? []).contains(where: { host.lowercased().contains($0.lowercased()) }) else { continue }
                var result = URLComponents(url: target, resolvingAgainstBaseURL: true)
                result?.scheme = url.scheme
                result?.host = host
                result?.port = url.port
                return result?.url
            }
            return nil
        }
        if let pattern = config.base64Pattern {
            for value in captures(pattern, in: html) {
                if let bytes = Data(base64Encoded: value), let text = String(data: bytes, encoding: .utf8),
                   let result = rewrite(captures(#"href=["'](https?://[^"']+)["']"#, in: text)) { return result }
            }
        }
        if let dataPattern = config.dataPattern, let keyPattern = config.keyPattern {
            for key in captures(keyPattern, in: html).reversed() {
                for encoded in captures(dataPattern, in: html).reversed() {
                    guard let payload = Data(base64Encoded: encoded), payload.count > 16,
                          let plain = SiteCrypto.decrypt(Data(payload.dropFirst(16)), key: Data(SHA256.hash(data: Data(key.utf8))), iv: Data(payload.prefix(16))),
                          let object = try? JSONSerialization.jsonObject(with: plain) else { continue }
                    if let identity = config.identityPattern {
                        let text = (config.identityPaths ?? []).flatMap { values(at: $0, in: object) }.joined(separator: " ")
                        guard text.range(of: identity, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                    }
                    if let result = rewrite((config.urlPaths ?? []).flatMap { values(at: $0, in: object) }) { return result }
                }
            }
            return nil
        }
        return rewrite(captures(#"href=["'](https?://[^"']+)["']"#, in: html))
    }

    static func request(config: SitePortal) -> URLRequest? {
        guard let portal = URL(string: config.url) else { return nil }
        var request = URLRequest(url: portal)
        request.timeoutInterval = 10
        for (name, value) in config.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func fetch(config: SitePortal, target: URL) async -> URL? {
        guard let request = request(config: config), let portal = request.url else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return resolve(in: html, portal: portal, target: target, config: config)
    }
}
