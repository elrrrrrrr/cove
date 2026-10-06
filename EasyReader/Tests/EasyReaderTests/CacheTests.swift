import XCTest
import UIKit
@testable import EasyReader

private actor ImageFixtureTransport: ImageTransport {
    let bytes: Data
    let delay: Duration
    private(set) var calls = 0
    private(set) var cancellations = 0
    init(bytes: Data, delay: Duration = .milliseconds(150)) { self.bytes = bytes; self.delay = delay }
    func data(for request: ImageRequest) async throws -> Data {
        calls += 1
        do { try await Task.sleep(for: delay); return bytes }
        catch { cancellations += 1; throw error }
    }
    func counts() -> (Int, Int) { (calls, cancellations) }
}

@MainActor final class CacheTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func png() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try XCTUnwrap(image.pngData())
    }
    private func request() -> ImageRequest {
        ImageRequest(url: URL(string: "https://media.example/cover.png?variant=one")!,
                     sourceID: UUID().uuidString, sourceRevision: "rule-1", assetRevision: "size:mtime", pixels: 240)
    }
    func testImageKeysIncludeSourcePixelsFileVersionCookiesAndTransforms() {
        let original = request()
        var changed = original; changed.pixels = 480
        XCTAssertNotEqual(original.key, changed.key); XCTAssertEqual(original.rawKey, changed.rawKey)
        changed = original; changed.sourceID = "another"
        XCTAssertNotEqual(original.rawKey, changed.rawKey)
        changed = original; changed.assetRevision = "new-mtime"
        XCTAssertNotEqual(original.rawKey, changed.rawKey)
        changed = original; changed.sourceRevision = "new-rule"
        XCTAssertNotEqual(original.rawKey, changed.rawKey)
        changed = original; changed.headers["Cookie"] = "account=two"
        XCTAssertNotEqual(original.rawKey, changed.rawKey)
        changed = original; changed.transform = SiteImageTransform(key: "0123456789abcdef", iv: "abcdef0123456789")
        XCTAssertNotEqual(original.rawKey, changed.rawKey)
        changed = original; changed.url = URL(string: "https://media.example/cover.png?variant=two")!
        XCTAssertNotEqual(original.rawKey, changed.rawKey)
    }
    func testCacheFilenameCannotContainURLPathsOrTraversal() {
        let key = "https://evil.example/x/%2e%2e/%2e%2e/%2e%2e/library.store"
        let name = DiskCache.filename(key: key, suffix: "../library.store")
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains(".."))
        XCTAssertEqual((name as NSString).pathExtension, "cache")
        XCTAssertEqual(name.count, 70)
    }
    func testDiskTTLAndIncrementalEviction() async throws {
        let cache = DiskCache(root: root(), maxBytes: 10, maxEntries: 2)
        let now = Date.now
        try await cache.store(Data(repeating: 1, count: 6), for: "one", ttl: 100, now: now)
        try await cache.store(Data(repeating: 2, count: 6), for: "two", ttl: 100, now: now.addingTimeInterval(1))
        let first = await cache.data(for: "one"), second = await cache.data(for: "two")
        XCTAssertNil(first); XCTAssertEqual(second?.count, 6)
        let usage = await cache.usage(); XCTAssertEqual(usage.bytes, 6); XCTAssertEqual(usage.count, 1)
        let expired = await cache.data(for: "two", now: now.addingTimeInterval(102))
        XCTAssertNil(expired)
    }
    func testDiskStartupReconcilesMissingAndOrphanedCacheFiles() async throws {
        let directory = root()
        let first = DiskCache(root: directory, maxBytes: 100, maxEntries: 2)
        try await first.store(Data([1, 2, 3]), for: "missing", ttl: 100)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(DiskCache.filename(key: "missing")))
        let orphan = directory.appendingPathComponent(DiskCache.filename(key: "orphan"))
        try Data([4]).write(to: orphan)
        let reopened = DiskCache(root: directory, maxBytes: 100, maxEntries: 2)
        let usage = await reopened.usage()
        XCTAssertEqual(usage.bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
    func testDiskRejectsSymlinksWithoutReadingOrDeletingTheirTarget() async throws {
        let directory = root(), target = root()
        try Data([9, 8, 7]).write(to: target)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: target) }
        let cache = DiskCache(root: directory, maxBytes: 100, maxEntries: 2)
        try await cache.store(Data([1, 2, 3]), for: "one", ttl: 100)
        let file = directory.appendingPathComponent(DiskCache.filename(key: "one"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let content = await cache.data(for: "one")
        XCTAssertNil(content)
        XCTAssertEqual(try Data(contentsOf: target), Data([9, 8, 7]))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let reopened = DiskCache(root: directory, maxBytes: 100, maxEntries: 2)
        let recovered = await reopened.data(for: "one")
        XCTAssertNil(recovered)
        XCTAssertEqual(try Data(contentsOf: target), Data([9, 8, 7]))
    }
    func testDecodedMemoryCacheHonorsExpiry() throws {
        let bytes = try png()
        let image = try XCTUnwrap(ImageDecoder.thumbnail(data: bytes, pixels: 32))
        let key = UUID().uuidString
        DecodedImageCache.shared.put(image, key: key, ttl: 0)
        XCTAssertNil(DecodedImageCache.shared.get(key))
    }
    func testTwelveMegapixelImageDownsamplesToRequestedDimensions() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000),
            format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }()).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let jpeg = try XCTUnwrap(source.jpegData(compressionQuality: 0.8))
        let result = try XCTUnwrap(ImageDecoder.thumbnail(data: jpeg, pixels: 480))
        XCTAssertEqual(result.image.cgImage?.width, 480)
        XCTAssertEqual(result.image.cgImage?.height, 360)
        XCTAssertLessThanOrEqual(result.cost, 480 * 360 * 4 + 360 * 64)
        let file = root().appendingPathExtension("jpg")
        try jpeg.write(to: file)
        XCTAssertEqual(ImageDecoder.thumbnail(file: file, pixels: 240)?.image.cgImage?.width, 240)
    }
    func testSharedImageCancellationDoesNotCancelOtherSubscriber() async throws {
        let fixture = ImageFixtureTransport(bytes: try png())
        let pipeline = ImagePipeline(root: root(), transport: fixture), request = request()
        let first = Task { await pipeline.image(request) }
        let second = Task { await pipeline.image(request) }
        try await Task.sleep(for: .milliseconds(30)); first.cancel()
        let cancelled = await first.value, completed = await second.value
        XCTAssertNil(cancelled); XCTAssertNotNil(completed)
        let counts = await fixture.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 0)
        let warm = await pipeline.image(request)
        XCTAssertNotNil(warm)
        let afterWarm = await fixture.counts(); XCTAssertEqual(afterWarm.0, 1)
    }
    func testLastSubscriberCancellationCancelsUnderlyingFetch() async throws {
        let fixture = ImageFixtureTransport(bytes: try png(), delay: .seconds(2))
        let pipeline = ImagePipeline(root: root(), transport: fixture), request = request()
        let task = Task { await pipeline.image(request) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        let result = await task.value; XCTAssertNil(result)
        let counts = await fixture.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }
    func testCancelledQueuedSlotDoesNotLeakCapacity() async throws {
        let slots = AsyncSlots(limit: 1)
        let first = await slots.acquire(); XCTAssertTrue(first)
        let waiting = Task { await slots.acquire() }
        try await Task.sleep(for: .milliseconds(10)); waiting.cancel()
        let cancelled = await waiting.value; XCTAssertFalse(cancelled)
        await slots.release()
        let next = await slots.acquire(); XCTAssertTrue(next)
        await slots.release()
    }
}
