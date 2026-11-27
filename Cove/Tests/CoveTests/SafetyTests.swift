import XCTest
import ZIPFoundation
@testable import Cove

final class SafetyTests: XCTestCase {
    func testReaderContainedPathRejectsTraversalSymlinksAndRoot() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        XCTAssertThrowsError(try ReaderContainedPath.resolve(".", under: temp))
        XCTAssertThrowsError(try ReaderContainedPath.resolve("../escape.txt", under: temp))
        XCTAssertThrowsError(try ReaderContainedPath.resolve("/etc/passwd", under: temp))
        XCTAssertThrowsError(try ReaderContainedPath.resolve("a\\b.txt", under: temp))

        let link = temp.appendingPathComponent("symlink-dir")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try ReaderContainedPath.resolve("symlink-dir/evil.txt", under: temp))

        let ok = try ReaderContainedPath.resolve("chapters/ch1.html", under: temp)
        XCTAssertTrue(ok.path.hasPrefix(temp.standardizedFileURL.resolvingSymlinksInPath().path))
    }

    func testReaderArchiveEnforcesExpansionLimits() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let zipURL = temp.appendingPathComponent("test.cbz")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let payload = Data(repeating: 0x41, count: 1024)
        try archive.addEntry(with: "page1.jpg", type: .file, uncompressedSize: Int64(payload.count)) { position, size in
            payload.subdata(in: Int(position)..<Int(position) + size)
        }

        let outFail = temp.appendingPathComponent("out-fail")
        XCTAssertThrowsError(try ReaderArchive.extract(archiveURL: zipURL, to: outFail, maxEntryBytes: 512, maxTotalBytes: 2048))

        let outOK = temp.appendingPathComponent("out-ok")
        let extracted = try ReaderArchive.extract(archiveURL: zipURL, to: outOK)
        XCTAssertEqual(extracted.count, 1)
    }

    func testWebURLSafetyRejectsUnsafeSchemes() {
        XCTAssertTrue(WebURLSafety.isWebURL(URL(string: "https://example.com/path")!))
        XCTAssertTrue(WebURLSafety.isWebURL(URL(string: "HTTP://example.com/")!))
        XCTAssertFalse(WebURLSafety.isWebURL(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(WebURLSafety.isWebURL(URL(string: "file:///etc/passwd")!))
        XCTAssertTrue(WebURLSafety.isMediaURL(URL(string: "data:image/png;base64,iVBOR")!))
    }
}
