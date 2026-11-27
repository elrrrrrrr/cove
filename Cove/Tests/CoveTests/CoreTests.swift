import XCTest
@testable import Cove

final class CoreTests: XCTestCase {
    func testBentoGrouperCoversAllItemsWithoutSkipping() {
        for count in [0, 1, 2, 3, 5, 10, 23] {
            for cols in [2, 3] {
                let slots = BentoGrouper.group(count: count, columns: cols)
                var seen: [Int] = []
                for slot in slots {
                    switch slot.kind {
                    case .fullWidth(let i): seen.append(i)
                    case .smallRow(let indices): seen.append(contentsOf: indices)
                    case .largeLeftSmallRight(let l, let t, let b),
                         .smallLeftLargeRight(let t, let b, let l):
                        seen.append(contentsOf: [t, b, l])
                    }
                }
                XCTAssertEqual(seen.sorted(), Array(0..<count))
            }
        }
    }

    func testReadingHistoryProgressSummaryAndRestoredIndex() {
        let video = ReadingHistory(title: "v", url: "https://example.com/v/1", fileType: .video, progress: 125)
        XCTAssertTrue(video.isWebVideoPlayback)
        XCTAssertEqual(video.progressSummary, "02:05")

        let epub = ReadingHistory(title: "b", filePath: "/tmp/book.epub", fileType: .epub, progress: 0.5)
        XCTAssertFalse(epub.isWebVideoPlayback)
        XCTAssertEqual(epub.progressSummary, "50%")
        XCTAssertEqual(ReadingHistory.restoredIndex(progress: 0.1, count: 10), 0)
        XCTAssertEqual(ReadingHistory.restoredIndex(progress: 1.0, count: 10), 9)
    }

    func testSMBURLNormalizationAndRangeSourceLimit() async throws {
        XCTAssertEqual(SMBClient.smbURL(host: "192.168.1.5")?.absoluteString, "smb://192.168.1.5")
        XCTAssertEqual(SMBClient.smbURL(host: "smb://nas.local:4445")?.absoluteString, "smb://nas.local:4445")
        XCTAssertNil(SMBClient.smbURL(host: "   "))

        struct HugeSource: SMBRangeSource {
            func fileSize(at path: String) async throws -> Int64 { 64 * 1024 * 1024 }
            func readRange(at path: String, offset: UInt64, length: Int) async throws -> Data { Data() }
        }
        do {
            _ = try await SMBFileRead.data(from: HugeSource(), path: "/big.png")
            XCTFail("Expected tooLarge error")
        } catch let error as SMBError {
            if case .tooLarge = error {} else { XCTFail("Wrong SMBError: \(error)") }
        }
    }
}
