import XCTest
import UIKit
import Network
import CommonCrypto
@testable import Cove

@MainActor final class ThumbnailContextTests: XCTestCase {
    private func definition(_ id: String, key: String) -> SiteDefinition {
        var value = SiteDefinition.starter(name: "Fixture", url: URL(string: "https://original.example/")!)
        value.id = id
        value.images = SiteImageTransform(hosts: ["original-cdn.example"], key: key, iv: "0000000000000000")
        return value
    }
    func testExplicitOwnerFindsTransformAfterPageAndImageHostsChange() throws {
        let previous = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        let owner = definition("fixture.owner", key: "1111111111111111")
        SiteParserRegistry.replaceDefinitions([owner])
        let image = URL(string: "https://new-cdn.example/cover.bin")!, page = URL(string: "https://mirror.example/post/1")!
        XCTAssertNil(SiteParserRegistry.imageTransform(for: image, referer: page))
        XCTAssertEqual(SiteParserRegistry.imageTransform(for: image, referer: page, definitionID: owner.id), owner.images)
        XCTAssertNil(SiteParserRegistry.imageTransform(for: image, referer: page, definitionID: "missing"))
    }
    func testImageCacheSeparatesOwnerRefererAndTransformRevision() throws {
        let previous = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        var owner = definition("fixture.a", key: "1111111111111111")
        let other = definition("fixture.b", key: "2222222222222222")
        SiteParserRegistry.replaceDefinitions([owner, other])
        let url = URL(string: "https://cdn.example/" + UUID().uuidString)!, page = URL(string: "https://mirror.example/post/1")!
        let first = ThumbnailRequest(url: url, referer: page, definitionID: owner.id)
        let second = ThumbnailRequest(url: url, referer: page, definitionID: other.id)
        XCTAssertNotEqual(first.cacheID, second.cacheID)
        let picture = try XCTUnwrap(UIImage(data: png(width: 32)))
        ImageMemoryCache.shared.store(picture, for: first)
        XCTAssertNotNil(ImageMemoryCache.shared.image(for: first))
        XCTAssertNil(ImageMemoryCache.shared.image(for: second))
        XCTAssertNil(ImageMemoryCache.shared.image(for: url))
        let differentPage = ThumbnailRequest(url: url, referer: URL(string: "https://mirror.example/post/2")!, definitionID: owner.id)
        XCTAssertNotEqual(first.cacheID, differentPage.cacheID)
        owner.images?.iv = "3333333333333333"
        SiteParserRegistry.replaceDefinitions([owner, other])
        XCTAssertNotEqual(first.cacheID, ThumbnailRequest(url: url, referer: page, definitionID: owner.id).cacheID)
    }
    func testEncryptedImagesDecodeAndReuseOnlyTheirRequestContext() async throws {
        let previous = SiteParserRegistry.definitions
        defer { SiteParserRegistry.replaceDefinitions(previous) }
        let one = definition("fixture.one", key: "1111111111111111"), two = definition("fixture.two", key: "2222222222222222")
        SiteParserRegistry.replaceDefinitions([one, two])
        let first = try encrypt(png(width: 32), transform: one.images!)
        let second = try encrypt(png(width: 48), transform: two.images!)
        let server = try ImageFixtureServer { headers in headers.contains("source-one.example") ? first : second }
        defer { server.listener.cancel() }
        let r1 = ThumbnailRequest(url: server.url, referer: URL(string: "https://source-one.example:8443/post/1")!, definitionID: one.id)
        let r2 = ThumbnailRequest(url: server.url, referer: URL(string: "https://source-two.example/post/1")!, definitionID: two.id)
        let result1 = await ImagePipeline.shared.data(for: r1)
        let result2 = await ImagePipeline.shared.data(for: r2)
        let bytes1 = try XCTUnwrap(result1), bytes2 = try XCTUnwrap(result2)
        XCTAssertEqual(UIImage(data: bytes1)?.cgImage?.width, 32)
        XCTAssertEqual(UIImage(data: bytes2)?.cgImage?.width, 48)
        let cached = await ImagePipeline.shared.data(for: r1)
        XCTAssertEqual(cached, bytes1); XCTAssertEqual(server.count.value, 2)
        let rendered1 = await ImagePipeline.shared.image(for: r1)
        let rendered2 = await ImagePipeline.shared.image(for: r2)
        XCTAssertEqual(rendered1?.cgImage?.width, 32); XCTAssertEqual(rendered2?.cgImage?.width, 48)
        XCTAssertEqual(server.count.value, 2)
        XCTAssertNotNil(ImageMemoryCache.shared.image(for: r1))
        XCTAssertNotNil(ImageMemoryCache.shared.image(for: r2))
    }
    func testActorSearchEncodesKeywordAsOneValue() throws {
        var site = SiteDefinition.starter(name: "Search", url: URL(string: "https://media.example/")!)
        site.rules[0].searchURLTemplate = "?q={keyword}&page=1"
        let parser = SiteParserRegistry.parser(definition: site, rule: site.rules[0])
        let keyword = "演员 A&B=1#标签"
        let url = try XCTUnwrap(parser.searchURL(keyword: keyword, base: URL(string: "https://mirror.example/")))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.count, 2); XCTAssertEqual(query.first?.value, keyword)
        XCTAssertEqual(query.last?.value, "1"); XCTAssertNil(url.fragment)
    }
    private func png(width: Int) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: 16), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
        }.pngData()!
    }
    private func encrypt(_ input: Data, transform: SiteImageTransform) throws -> Data {
        let key = Data(transform.key.utf8), iv = Data(transform.iv.utf8)
        var output = Data(count: input.count + 16), length = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { bytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, bytes.baseAddress, input.count, out.baseAddress, capacity, &length)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess)); output.removeSubrange(length..<output.count); return output
    }
}

final class ImageFixtureServer {
    let listener: NWListener
    let url: URL
    let count = ImageRequestCounter()
    init(reply: @escaping @Sendable (String) -> Data) throws {
        let ready = DispatchSemaphore(value: 0), queue = DispatchQueue(label: "CoveImageFixture")
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let counter = count
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { request, _, _, _ in
                counter.increment()
                let body = reply(String(data: request ?? Data(), encoding: .utf8) ?? "")
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else { throw NSError(domain: "ImageFixture", code: 1) }
        url = URL(string: "http://127.0.0.1:\(port.rawValue)/cover.bin")!
    }
}
final class ImageRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
