import XCTest
@testable import EasyReader

final class ReaderFileSafetyTests: XCTestCase {
    func testEscapingArchivePathsAndSiblingPrefixesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside", "/absolute", "../../outside", "folder/../../outside", "\\outside"] {
            XCTAssertThrowsError(try ReaderContainedPath.resolve(path, under: root))
        }
        XCTAssertEqual(try ReaderContainedPath.resolve("folder/../page.jpg", under: root), root.appendingPathComponent("page.jpg"))
    }
    func testRestoredThumbnailPathsReuseSafeLegacyFilesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = ThumbnailCache.legacyFile(for: URL(string: "https://media.example/covers/1.jpg")!, under: root)
        XCTAssertEqual(valid?.lastPathComponent, "1.jpg")
        XCTAssertTrue(valid?.path.hasPrefix(root.path + "/media.example/") == true)
        XCTAssertNil(ThumbnailCache.legacyFile(for: URL(string: "https://evil.example/x/%2e%2e/%2e%2e/Cove.store")!, under: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("media.example"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertNil(ThumbnailCache.legacyFile(for: URL(string: "https://media.example/covers/1.jpg")!, under: root))
    }
    func testSymlinkParentWithNonexistentLeafIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try ReaderContainedPath.resolve("link/not-created.jpg", under: root))
    }
}
