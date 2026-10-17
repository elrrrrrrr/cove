import XCTest
import WebKit
@testable import Cove

@MainActor final class SiteLoginTests: XCTestCase {
    func testRecordsMatchOnlyTheSiteAndItsParentDomain() {
        XCTAssertTrue(SiteWebSession.matches(recordDomain: "example.com", host: "account.example.com"))
        XCTAssertTrue(SiteWebSession.matches(recordDomain: ".EXAMPLE.com", host: "example.com"))
        XCTAssertFalse(SiteWebSession.matches(recordDomain: "example.com", host: "evil-example.com"))
        XCTAssertFalse(SiteWebSession.matches(recordDomain: "example.com", host: "example.com.evil.test"))
        XCTAssertFalse(SiteWebSession.matches(recordDomain: "", host: "example.com"))
        XCTAssertFalse(SiteWebSession.matches(recordDomain: "account.example.com", host: "example.com"))
    }

    func testTargetsGroupHostsAndRejectUnsafeEntrypoints() {
        let sites = [
            BookmarkSite(name: "动态", urlString: "https://news.example/home"),
            BookmarkSite(name: "分类", urlString: "https://NEWS.example/category"),
            BookmarkSite(name: "另一个网站", urlString: "https://other.example/"),
            BookmarkSite(name: "本地文件", urlString: "file:///tmp/book.html"),
            BookmarkSite(name: "含凭据", urlString: "https://user:secret@private.example/"),
            BookmarkSite(name: "脚本", urlString: "javascript:alert(1)")
        ]
        let targets = SiteLoginTarget.targets(for: sites)
        XCTAssertEqual(targets.map(\.host), ["news.example", "other.example"])
        XCTAssertEqual(targets.first?.url.path, "/home")
        XCTAssertEqual(targets.first?.name, "动态")
    }

    func testClearSiteCookiesPreservesAnotherWebsite() async throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let host = "a-" + token + ".example", otherHost = "b-" + token + ".example"
        func cookie(_ host: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [.domain: host, .path: "/", .name: "synthetic", .value: "test-only", .expires: Date().addingTimeInterval(3600)]))
        }
        let first = try cookie(host), other = try cookie(otherHost)
        let store = SiteWebSession.dataStore.httpCookieStore
        await store.setCookie(first); await store.setCookie(other)
        await SiteWebSession.clearLoginData(for: host)
        let remaining = await store.allCookies()
        XCTAssertFalse(remaining.contains { $0.domain == host && $0.name == first.name })
        XCTAssertTrue(remaining.contains { $0.domain == otherHost && $0.name == other.name })
        await store.deleteCookie(first); await store.deleteCookie(other)
    }
}
