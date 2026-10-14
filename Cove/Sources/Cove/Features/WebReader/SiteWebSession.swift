import WebKit

/// One persistent WebKit store for login, parsing and original pages.
/// Keep the default store so existing website sessions survive app updates.
/// Content cache cleanup must not delete this store or export its credentials.
@MainActor enum SiteWebSession {
    static let dataStore = WKWebsiteDataStore.default()
}
