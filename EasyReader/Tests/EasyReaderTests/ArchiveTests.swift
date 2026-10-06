import XCTest
@testable import EasyReader

final class ArchiveTests: XCTestCase {
    private func archive(_ name: String, ext: String = "epub") throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Archives"))
    }
    func testContainmentRejectsTraversalAbsoluteAndSiblingPrefixes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("allowed-" + UUID().uuidString)
        XCTAssertThrowsError(try ContainedPath.resolve("../outside", under: root))
        XCTAssertThrowsError(try ContainedPath.resolve("/private/outside", under: root))
        XCTAssertThrowsError(try ContainedPath.resolve("../" + root.lastPathComponent + "-sibling/outside", under: root))
        XCTAssertThrowsError(try ContainedPath.resolve("sub//../../outside", under: root))
        XCTAssertThrowsError(try ContainedPath.resolve("..\\outside", under: root))
        XCTAssertEqual(try ContainedPath.resolve("sub/../inside.png", under: root).lastPathComponent, "inside.png")
    }
    func testContainmentRejectsExistingEscapingSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try ContainedPath.resolve("link/outside.png", under: root))
    }
    func testComicZIPNaturalPageOrderAndMacMetadataFiltering() throws {
        let document = try ArchiveService.open(archive("comic", ext: "cbz"))
        let pages = try ArchiveService.comicPages(document)
        XCTAssertEqual(pages.map(\.lastPathComponent), ["1.png", "2.png", "10.png"])
        XCTAssertTrue(pages.allSatisfy { $0.path.hasPrefix(document.root.path + "/") })
    }
    func testZIPRejectsTraversalSymlinksAndOversizedEntryBeforeExtraction() throws {
        for name in ["traversal", "symlink", "oversize"] {
            XCTAssertThrowsError(try ArchiveService.open(archive(name, ext: "cbz")), name)
        }
    }
    func testEPUBContainerAndManifestReferencesAreConfined() throws {
        for name in ["bad-container", "bad-manifest", "bad-encoded", "bad-absolute"] {
            XCTAssertThrowsError(try EPUBParser.parse(fileURL: archive(name)), name)
        }
        let book = try EPUBParser.parse(fileURL: archive("inside-relative"))
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].htmlURL.path.hasPrefix(book.document.root.path + "/"))
    }
    func testValidEPUBHasOwnedDocumentAndChapters() throws {
        let book = try EPUBParser.parse(fileURL: archive("book"))
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].htmlURL.lastPathComponent, "chapter.xhtml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.chapters[0].htmlURL.path))
    }
    func testRARIsNotFalselyPassedToZIPDecoder() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("rar")
        try Data("not a zip".utf8).write(to: file)
        XCTAssertThrowsError(try ArchiveService.open(file)) { XCTAssertTrue($0.localizedDescription.contains("RAR")) }
    }
}
