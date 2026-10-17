import WebKit

/// One persistent WebKit store for login, parsing and original pages.
/// Keep the default store so existing website sessions survive app updates.
/// Content cache cleanup must not delete this store or export its credentials.
@MainActor enum SiteWebSession {
    static let dataStore = WKWebsiteDataStore.default()
    static let loginDataTypes: Set<String> = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage,
                                              WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases]

    /// WebKit records may cover a parent domain shared by several site entries.
    static func matches(recordDomain: String, host: String) -> Bool {
        let domain = recordDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return !domain.isEmpty && !host.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    static func records(for host: String) async -> [WKWebsiteDataRecord] {
        await dataStore.dataRecords(ofTypes: loginDataTypes).filter { matches(recordDomain: $0.displayName, host: host) }
    }

    static func hasLoginData(for host: String) async -> Bool {
        if !(await records(for: host)).isEmpty { return true }
        return await dataStore.httpCookieStore.allCookies().contains { matches(recordDomain: $0.domain, host: host) }
    }

    static func clearLoginData(for host: String) async {
        let records = await records(for: host)
        await dataStore.removeData(ofTypes: loginDataTypes, for: records)
        // Include cookie-only domains even when WebKit has not produced a data record yet.
        for cookie in await dataStore.httpCookieStore.allCookies() where matches(recordDomain: cookie.domain, host: host) {
            await dataStore.httpCookieStore.delete(cookie)
        }
    }
}

struct SiteLoginTarget: Identifiable, Hashable {
    let host: String
    let name: String
    let url: URL
    var id: String { host }

    @MainActor static func targets(for sites: [BookmarkSite]) -> [Self] {
        var seen: Set<String> = []
        return sites.compactMap { site in
            guard let url = site.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, let host = url.host?.lowercased(),
                  !host.isEmpty, seen.insert(host).inserted else { return nil }
            return Self(host: host, name: site.name, url: url)
        }
    }
}
