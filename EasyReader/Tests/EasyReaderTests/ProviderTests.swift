import XCTest
import AVFoundation
import SwiftData
import AVFoundation
@testable import EasyReader

private actor FixtureRangeReader: RangeReader {
    let bytes: Data
    private(set) var lengths: [Int] = []
    init(bytes: Data) { self.bytes = bytes }
    func size(path: String) async throws -> Int64 { Int64(bytes.count) }
    func readRange(path: String, offset: UInt64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        lengths.append(length)
        let start = min(bytes.count, Int(offset)), end = min(bytes.count, start + length)
        return bytes.subdata(in: start..<end)
    }
    func requestedLengths() -> [Int] { lengths }
}

@MainActor final class ProviderTests: XCTestCase {
    func testFolderCacheExpiresOnExplicitRefreshAndFileRevisionChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("book.txt"))
        let source = SourceDefinition(id: "example.files", name: "文件", source: SourceConnection(adapter: .files))
        let provider = try FileSourceProvider(definition: source, root: root)
        defer { provider.close() }
        let first = try await provider.list(CollectionRequest(locator: "/"))
        try Data("two".utf8).write(to: root.appendingPathComponent("second.txt"))
        let cached = try await provider.list(CollectionRequest(locator: "/"))
        XCTAssertEqual(first.items, cached.items)
        try Data("changed bytes".utf8).write(to: root.appendingPathComponent("book.txt"))
        let updated = try await provider.list(CollectionRequest(locator: "/", forceRefresh: true))
        XCTAssertEqual(updated.items.count, 2)
        let book = try XCTUnwrap(updated.items.first { $0.title == "book.txt" })
        XCTAssertEqual(book.id, first.items[0].id)
        XCTAssertNotEqual(book.revision, first.items[0].revision)
    }
    func testProviderRegistryDoesNotRetainInactiveWebViews() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SourceStore(storageURL: root.appendingPathComponent("sources.json"), bindingURL: root.appendingPathComponent("folders.json"))
        let source = SourceDefinition.starter(name: "测试", adapter: .web, url: "https://media.example")
        try store.save(source)
        var provider: (any SourceProvider)? = try store.provider(id: source.id)
        weak let weakProvider = provider
        XCTAssertTrue(try store.provider(id: source.id) === provider)
        provider = nil
        XCTAssertNil(weakProvider)
    }
    func testCookieProfilesDoNotShareLoginAndPathBoundaryIsRespected() async throws {
        let first = "test.profile." + UUID().uuidString
        let second = "test.profile." + UUID().uuidString
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "media.example", .path: "/private", .name: "account", .value: "one", .secure: "TRUE"]))
        await SourceWebSession.store(id: first).httpCookieStore.setCookie(cookie)
        let allowed = await SourceWebSession.cookieHeader(id: first, url: URL(string: "https://media.example/private/movie")!)
        let wrongPath = await SourceWebSession.cookieHeader(id: first, url: URL(string: "https://media.example/private-other")!)
        let other = await SourceWebSession.cookieHeader(id: second, url: URL(string: "https://media.example/private/movie")!)
        XCTAssertEqual(allowed, "account=one"); XCTAssertNil(wrongPath); XCTAssertNil(other)
        let subdomain = await SourceWebSession.cookieHeader(id: first, url: URL(string: "https://sub.media.example/private/movie")!)
        XCTAssertNil(subdomain)
        let rootCookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "media.example", .path: "/", .name: "root", .value: "yes"]))
        await SourceWebSession.store(id: first).httpCookieStore.setCookie(rootCookie)
        let emptyPath = await SourceWebSession.cookieHeader(id: first, url: URL(string: "https://media.example")!)
        XCTAssertEqual(emptyPath, "root=yes")
        let request = ImageRequest(url: URL(string: "https://media.example/private/movie")!, sourceID: first, sourceRevision: "one", pixels: 64)
        let authenticated = await SourceWebSession.imageRequest(request)
        XCTAssertTrue(authenticated.headers["Cookie"]?.contains("account=one") == true)
        XCTAssertNotEqual(authenticated.rawKey, request.rawKey)
    }
    func testHTTPMediaReachesReadyStateAndActuallyAdvancesPlayback() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4", subdirectory: "Media"))
        let server = try FixtureServer(routes: ["/sample.mp4": FixtureResponse(mime: "video/mp4", body: try Data(contentsOf: file))])
        let base = try await server.start(); defer { server.stop() }
        let url = base.appendingPathComponent("sample.mp4")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 2)
        let container = try ModelContainer(for: LibraryEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let library = LibraryStore(context: container.mainContext)
        let session = PlaybackSession()
        defer { session.stop() }
        await session.open(item: ResourceItem(sourceID: "test", title: "短视频", locator: url.absoluteString, kind: .video), asset: MediaAsset(url: url), provider: nil, library: library, autoplay: true)
        for _ in 0..<100 where session.playhead < 0.2 && session.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(session.error)
        XCTAssertGreaterThan(session.playhead, 0.2)
        XCTAssertGreaterThan(session.duration, 2)
    }
    func testSMBMediaAssetUsesBoundedRangeReadsInsteadOfWholeFile() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4", subdirectory: "Media"))
        let reader = FixtureRangeReader(bytes: try Data(contentsOf: file))
        let asset = try SMBStreamLoader.asset(client: reader, path: "/sample.mp4")
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 2)
        let lengths = await reader.requestedLengths()
        XCTAssertFalse(lengths.isEmpty)
        XCTAssertTrue(lengths.allSatisfy { $0 > 0 && $0 <= 512 * 1024 })
    }
    func testVideoThumbnailSharesPipelineAndTargetPixels() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "mp4", subdirectory: "Media"))
        let reader = FixtureRangeReader(bytes: try Data(contentsOf: file))
        let pipeline = ImagePipeline(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let request = ImageRequest(url: URL(string: "cove-thumbnail://resource/sample.mp4")!, sourceID: UUID().uuidString, sourceRevision: "one", assetRevision: "size:mtime", pixels: 32, video: true, rangeReader: reader, remotePath: "/sample.mp4")
        let image = await pipeline.image(request)
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(image?.image.cgImage?.width ?? .max, 32)
    }
    func testAllLocallyBundledDefinitionsValidateAndTheirScriptsCompile() async throws {
        let files = Bundle.main.urls(forResourcesWithExtension: "site", subdirectory: "Sites") ?? []
        let engine = WebEngine()
        try await engine.load(URL(string: "data:text/html,<p>syntax</p>")!)
        for file in files {
            let definition = try SourceDefinition.read(file)
            for module in [definition.modules?.catalog, definition.modules?.video, definition.modules?.comic, definition.modules?.chapter, definition.modules?.tags].compactMap({ $0 }) {
                for rule in [module] + (module.variants ?? []) where rule.request == nil {
                    let result = try await engine.execute("new Function('return async function(){' + body + '}'); return 'valid';", arguments: ["body": rule.javascript])
                    XCTAssertEqual(result, "valid", file.lastPathComponent)
                }
            }
            if let pagination = definition.modules?.pagination {
                for body in [pagination.script, pagination.expression.map { "return await (\($0));" }, pagination.thumbnailScript].compactMap({ $0 }) {
                    let result = try await engine.execute("new Function('return async function(page){' + body + '}'); return 'valid';", arguments: ["body": body])
                    XCTAssertEqual(result, "valid", file.lastPathComponent)
                }
            }
        }
    }
}
