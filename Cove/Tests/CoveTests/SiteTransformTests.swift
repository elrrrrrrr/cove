import XCTest
import CryptoKit
import CommonCrypto
@testable import Cove

final class SiteTransformTests: XCTestCase {
    func testPortalUsesConfiguredRequestHeaders() throws {
        let config = SitePortal(url: "https://portal.example", headers: ["User-Agent": "Cove Fixture", "Referer": "https://media.example/"])
        let request = try XCTUnwrap(SitePortalResolver.request(config: config))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Cove Fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://media.example/")
    }

    func testPortalUsesConfiguredJSONPathsAndPreservesTargetRoute() throws {
        let key = "fixture key"
        let iv = Data("0123456789abcdef".utf8)
        let plain = Data(#"{"label":"Fixture","routes":[{"address":"https://mirror.example:8443"}]}"#.utf8)
        let keyData = Data(SHA256.hash(data: Data(key.utf8)))
        let cipher = try encrypt(plain, key: keyData, iv: iv)
        let payload = (iv + cipher).base64EncodedString()
        let html = "const config = {payload:'\(payload)', secret:'\(key)'};"
        let config = SitePortal(url: "https://portal.example", dataPattern: #"payload:'([^']+)'"#,
            keyPattern: #"secret:'([^']+)'"#, urlPaths: ["routes.*.address"], identityPaths: ["label"], identityPattern: "Fixture")
        let target = URL(string: "https://portal.example/catalog/?page=2")!
        XCTAssertEqual(SitePortalResolver.resolve(in: html, portal: URL(string: config.url)!, target: target, config: config)?.absoluteString,
                       "https://mirror.example:8443/catalog/?page=2")
        var wrong = config; wrong.identityPattern = "Different"
        XCTAssertNil(SitePortalResolver.resolve(in: html, portal: URL(string: config.url)!, target: target, config: wrong))
    }

    func testBase64PortalAndInvalidCipher() {
        let content = #"<a href="https://mirror.example/">线路</a>"#
        let html = "decode('\(Data(content.utf8).base64EncodedString())')"
        let config = SitePortal(url: "https://portal.example", base64Pattern: #"decode\('([^']+)'\)"#)
        let target = URL(string: "https://portal.example/books/")!
        XCTAssertEqual(SitePortalResolver.resolve(in: html, portal: URL(string: config.url)!, target: target, config: config)?.host(), "mirror.example")
        XCTAssertNil(SiteCrypto.decrypt(Data([1, 2]), key: Data(repeating: 1, count: 16), iv: Data(repeating: 0, count: 16)))
    }

    private func encrypt(_ input: Data, key: Data, iv: Data) throws -> Data {
        var result = Data(count: input.count + 16), length = 0
        let capacity = result.count
        let status = result.withUnsafeMutableBytes { output in
            input.withUnsafeBytes { bytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, bytes.baseAddress, input.count, output.baseAddress, capacity, &length)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        result.removeSubrange(length..<result.count)
        return result
    }
}
