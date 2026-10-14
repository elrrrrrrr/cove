import XCTest
import ZIPFoundation
@testable import Cove

final class ReaderFileSafetyTests: XCTestCase {
    func testEPUBCacheSeparatesSameNamesAndReplacedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var caches: [URL] = []
        defer {
            try? FileManager.default.removeItem(at: root)
            for cache in caches { try? FileManager.default.removeItem(at: cache) }
        }
        func book(_ folder: String, _ content: String) throws -> URL {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("book.epub")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let archive = try Archive(url: url, accessMode: .create, pathEncoding: .utf8)
            let files = [
                "META-INF/container.xml": "<container><rootfiles><rootfile full-path='content.opf'/></rootfiles></container>",
                "content.opf": "<package><manifest><item id='chapter' href='chapter.xhtml'/></manifest><spine><itemref idref='chapter'/></spine></package>",
                "chapter.xhtml": content
            ]
            for (path, text) in files {
                let data = Data(text.utf8)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            }
            return url
        }
        let firstURL = try book("one", "<p>first book</p>")
        let first = try XCTUnwrap(EPUBParser.parse(fileURL: firstURL).first)
        caches.append(first.htmlURL.deletingLastPathComponent())
        let second = try XCTUnwrap(EPUBParser.parse(fileURL: book("two", "<p>second book</p>")).first)
        caches.append(second.htmlURL.deletingLastPathComponent())
        XCTAssertNotEqual(first.htmlURL, second.htmlURL)
        XCTAssertEqual(try String(contentsOf: second.htmlURL, encoding: .utf8), "<p>second book</p>")
        let replaced = try XCTUnwrap(EPUBParser.parse(fileURL: book("one", "<p>replacement has new contents</p>")).first)
        caches.append(replaced.htmlURL.deletingLastPathComponent())
        XCTAssertNotEqual(first.htmlURL, replaced.htmlURL)
        XCTAssertEqual(try String(contentsOf: replaced.htmlURL, encoding: .utf8), "<p>replacement has new contents</p>")
    }
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
        let valid = ImagePipeline.legacyFile(for: URL(string: "https://media.example/covers/1.jpg")!, under: root)
        XCTAssertEqual(valid?.lastPathComponent, "1.jpg")
        XCTAssertTrue(valid?.path.hasPrefix(root.path + "/media.example/") == true)
        XCTAssertNil(ImagePipeline.legacyFile(for: URL(string: "https://evil.example/x/%2e%2e/%2e%2e/Cove.store")!, under: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("media.example"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertNil(ImagePipeline.legacyFile(for: URL(string: "https://media.example/covers/1.jpg")!, under: root))
    }
    func testSymlinkParentWithNonexistentLeafIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try ReaderContainedPath.resolve("link/not-created.jpg", under: root))
    }
}
