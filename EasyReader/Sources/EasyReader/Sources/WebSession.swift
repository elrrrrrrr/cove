import WebKit

@MainActor enum SourceWebSession {
    private static var profiles: [String: (store: WKWebsiteDataStore, accessed: Date)] = [:]
    static func store(id: String?) -> WKWebsiteDataStore {
        guard let id else { return .nonPersistent() }
        if let existing = profiles[id] {
            profiles[id] = (existing.store, .now)
            return existing.store
        }
        let hash = StableHash.of("cove-web-profile:" + id)
        let value = "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\(hash.dropFirst(12).prefix(4))-\(hash.dropFirst(16).prefix(4))-\(hash.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else { return .nonPersistent() }
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        if profiles.count >= 64, let oldest = profiles.min(by: { $0.value.accessed < $1.value.accessed }) {
            profiles.removeValue(forKey: oldest.key)
        }
        profiles[id] = (store, .now)
        return store
    }
    static func imageRequest(_ request: ImageRequest) async -> ImageRequest {
        guard ["http", "https"].contains(request.url.scheme) else { return request }
        var result = request
        if let cookie = await cookieHeader(id: request.sourceID, url: request.url) { result.headers["Cookie"] = cookie }
        return result
    }
    static func cookieHeader(id: String, url: URL) async -> String? {
        let cookies = await store(id: id).httpCookieStore.allCookies()
        let host = url.host()?.lowercased() ?? ""
        let requestPath = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let pathMatches = requestPath == $0.path || (requestPath.hasPrefix($0.path) && ($0.path.hasSuffix("/") || requestPath.dropFirst($0.path.count).hasPrefix("/")))
            return (host == domain || ($0.domain.hasPrefix(".") && host.hasSuffix("." + domain))) && pathMatches
                && (!$0.isSecure || url.scheme == "https") && ($0.expiresDate.map { $0 > .now } ?? true)
        }
        return matching.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
}
