import XCTest
import UIKit
import ImageIO
@testable import Cove

@MainActor final class ImagePipelineTests: XCTestCase {
    private func jpeg(_ width: Int, _ height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill(); context.fill(CGRect(x: width / 2, y: height / 2, width: width / 4, height: height / 4))
        }.jpegData(compressionQuality: 0.8)!
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testLargeCoverHasDisplaySizedDecodeAndLowerByteCost() async throws {
        let data = jpeg(4000, 3000)
        let small = try XCTUnwrap(ImageDecoder.decode(data, sizing: .thumbnail(640)))
        XCTAssertEqual(small.cgImage?.width, 640); XCTAssertEqual(small.cgImage?.height, 480)
        XCTAssertLessThan(ImageDecoder.cost(small), 1_300_000)
        XCTAssertLessThan(ImageDecoder.cost(small), 4000 * 3000 * 4 / 30)
        let file = try directory().appendingPathComponent("page.jpg"); try data.write(to: file)
        let pipeline = ImagePipeline(root: try directory())
        let page = await pipeline.image(at: file, sizing: .page(width: 1024))
        XCTAssertEqual(page?.cgImage?.width, 1024)
    }
    func testLongComicPageUsesWidthAndEnforcesPixelBudget() throws {
        let data = jpeg(1000, 10_000)
        let page = try XCTUnwrap(ImageDecoder.decode(data, sizing: .page(width: 500)))
        XCTAssertEqual(page.cgImage?.width, 500); XCTAssertEqual(page.cgImage?.height, 5000)
        let bounded = try XCTUnwrap(ImageDecoder.decode(data, sizing: .page(width: 4000))?.cgImage)
        XCTAssertLessThanOrEqual(bounded.width * bounded.height, ImageDecoder.maximumPixels)
        XCTAssertGreaterThan(bounded.width, 800)
    }
    func testSmallImageIsNotUpscaledAndInvalidDataIsRejected() throws {
        let picture = try XCTUnwrap(ImageDecoder.decode(jpeg(32, 16), sizing: .thumbnail(512)))
        XCTAssertEqual(picture.cgImage?.width, 32)
        XCTAssertNil(ImageDecoder.decode(Data("not an image".utf8), sizing: .thumbnail(64)))
        XCTAssertFalse(ImageDecoder.isImage(Data()))
    }
    func testOrientationIsAppliedBeforeSizingPageWidth() throws {
        let original = jpeg(600, 1200)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let output = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(writer, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let rotated = try XCTUnwrap(ImageDecoder.decode(output as Data, sizing: .page(width: 300)))
        XCTAssertEqual(rotated.cgImage?.width, 300); XCTAssertEqual(rotated.cgImage?.height, 150)
    }
    func testDifferentDisplaySizesShareOneSourceDownload() async throws {
        let data = jpeg(1200, 800)
        let server = try ImageFixtureServer { _ in data }; defer { server.listener.cancel() }
        let pipeline = ImagePipeline(root: try directory())
        let source = ThumbnailRequest(url: server.url)
        let large = source.resized(.thumbnail(512)), small = source.resized(.thumbnail(128))
        XCTAssertEqual(large.resourceID, small.resourceID); XCTAssertNotEqual(large.cacheID, small.cacheID)
        async let first = pipeline.image(for: large)
        async let second = pipeline.image(for: small)
        let (a, b) = await (first, second)
        XCTAssertEqual(a?.cgImage?.width, 512); XCTAssertEqual(b?.cgImage?.width, 128)
        let again = await pipeline.image(for: large)
        XCTAssertEqual(again?.cgImage?.width, 512); XCTAssertEqual(server.count.value, 1)
    }
    func testCancellingOneSizeKeepsOtherSizeDownloadAlive() async throws {
        let data = jpeg(1200, 800)
        let server = try ImageFixtureServer { _ in Thread.sleep(forTimeInterval: 0.1); return data }
        defer { server.listener.cancel() }
        let pipeline = ImagePipeline(root: try directory()), source = ThumbnailRequest(url: server.url)
        let small = Task { await pipeline.image(for: source.resized(.thumbnail(128))) }
        let large = Task { await pipeline.image(for: source.resized(.thumbnail(512))) }
        for _ in 0..<100 { if server.count.value > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        small.cancel()
        let cancelled = await small.value, retained = await large.value
        XCTAssertNil(cancelled); XCTAssertEqual(retained?.cgImage?.width, 512)
        XCTAssertEqual(server.count.value, 1)
    }
    func testEncodedMemoryUsesLRUByteBudgetAndExpiresFromWriteTime() {
        var cache = ByteLRUCache<String>(byteLimit: 10, countLimit: 3, ttl: 10)
        let now = Date()
        cache.insert(Data(repeating: 1, count: 4), for: "a", now: now)
        cache.insert(Data(repeating: 2, count: 4), for: "b", now: now)
        XCTAssertNotNil(cache.value(for: "a", now: now.addingTimeInterval(5)))
        cache.insert(Data(repeating: 3, count: 4), for: "c", now: now)
        XCTAssertNil(cache.value(for: "b", now: now)); XCTAssertEqual(cache.byteCount, 8)
        cache.insert(Data(repeating: 4, count: 2), for: "a", now: now)
        XCTAssertEqual(cache.byteCount, 6)
        cache.insert(Data(count: 11), for: "oversized", now: now); XCTAssertEqual(cache.byteCount, 6)
        XCTAssertNil(cache.value(for: "a", now: now.addingTimeInterval(11)))
        cache.clear(); XCTAssertEqual(cache.byteCount, 0); XCTAssertEqual(cache.count, 0)
    }
    func testDecodedCacheRejectsIndividualImagesOverBudgetAndExpires() throws {
        let picture = try XCTUnwrap(ImageDecoder.decode(jpeg(64, 64), sizing: .thumbnail(64)))
        let small = ImageMemoryCache(costLimit: 100)
        small.store(picture, forKey: "over"); XCTAssertNil(small.image(forKey: "over"))
        let expired = ImageMemoryCache(ttl: -1)
        expired.store(picture, forKey: "expired"); XCTAssertNil(expired.image(forKey: "expired"))
    }
    func testNASKeysSeparateHostShareRevisionAndDisplaySize() {
        let now = Date(timeIntervalSince1970: 100)
        func entry(_ bytes: Int, _ date: Date?) -> NASFileEntry { .init(name: "page.jpg", path: "/page.jpg", isDirectory: false, size: bytes, modifiedAt: date) }
        let first = NASThumbnailCache.key(connectionID: "host-a/share-a", entry: entry(10, now), pixels: 128)
        XCTAssertNotEqual(first, NASThumbnailCache.key(connectionID: "host-b/share-a", entry: entry(10, now), pixels: 128))
        XCTAssertNotEqual(first, NASThumbnailCache.key(connectionID: "host-a/share-b", entry: entry(10, now), pixels: 128))
        XCTAssertNotEqual(first, NASThumbnailCache.key(connectionID: "host-a/share-a", entry: entry(11, now), pixels: 128))
        XCTAssertNotEqual(first, NASThumbnailCache.key(connectionID: "host-a/share-a", entry: entry(10, now.addingTimeInterval(1)), pixels: 128))
        XCTAssertNotEqual(first, NASThumbnailCache.key(connectionID: "host-a/share-a", entry: entry(10, now), pixels: 512))
        XCTAssertEqual(first, NASThumbnailCache.key(connectionID: "host-a/share-a", entry: entry(10, now), pixels: 128))
    }
}
