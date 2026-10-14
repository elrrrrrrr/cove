import XCTest
@testable import Cove

@MainActor final class NASBoundedIOTests: XCTestCase {
    func testLargeFileIsRejectedBeforeAnyMemoryRead() async throws {
        let source = FakeRangeSource(size: 5 * 1024 * 1024 * 1024)
        do {
            _ = try await SMBFileRead.data(from: source, path: "/large.mov")
            XCTFail("Large files must stream or download to disk")
        } catch SMBError.tooLarge { }
        let reads = await source.lengths
        XCTAssertTrue(reads.isEmpty)
    }

    func testImageReadUsesBoundedRangesAndPreservesBytes() async throws {
        let size = SMBFileRead.chunkBytes * 2 + 17
        let source = FakeRangeSource(size: Int64(size))
        let data = try await SMBFileRead.data(from: source, path: "/image.jpg")
        XCTAssertEqual(data, Data(repeating: 42, count: size))
        let reads = await source.lengths
        XCTAssertEqual(reads, [SMBFileRead.chunkBytes, SMBFileRead.chunkBytes, 17])
    }

    func testCancellationStopsAnInFlightMemoryRead() async throws {
        let source = FakeRangeSource(size: Int64(SMBFileRead.chunkBytes * 3), pause: true)
        let task = Task { try await SMBFileRead.data(from: source, path: "/image.jpg") }
        await source.waitForRead()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read completed") }
        catch is CancellationError { }
        let reads = await source.lengths
        XCTAssertEqual(reads.count, 1)
    }

    func testDownloadStopsOnUnknownSizeGrowthOrCancellation() throws {
        let budget = SMBTransferControl(maxBytes: 1024)
        XCTAssertTrue(budget.accept(completed: 512, total: 0))
        XCTAssertFalse(budget.accept(completed: 1025, total: 0))
        XCTAssertFalse(budget.accept(completed: 1, total: 1))
        XCTAssertThrowsError(try budget.check())
        let cancelled = SMBTransferControl(maxBytes: 1024)
        cancelled.cancel()
        XCTAssertFalse(cancelled.accept(completed: 0, total: 0))
        XCTAssertThrowsError(try cancelled.check()) { XCTAssertTrue($0 is CancellationError) }
    }
}

private actor FakeRangeSource: SMBRangeSource {
    let size: Int64
    let pause: Bool
    var lengths: [Int] = []
    private var started: CheckedContinuation<Void, Never>?
    init(size: Int64, pause: Bool = false) { self.size = size; self.pause = pause }
    func fileSize(at path: String) async throws -> Int64 { size }
    func waitForRead() async {
        if !lengths.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }
    func readRange(at path: String, offset: UInt64, length: Int) async throws -> Data {
        lengths.append(length)
        started?.resume(); started = nil
        if pause { try await Task.sleep(for: .seconds(30)) }
        return Data(repeating: 42, count: length)
    }
}

@MainActor final class SMBResourceCancellationTests: XCTestCase {
    func testPlayerTeardownCancelsPendingRangeRead() async throws {
        let source = CancellableSMBFixture()
        let asset = SMBStreamLoader.makeAsset(client: source, remotePath: "/fixture.mp4")
        let load = Task { try? await asset.load(.duration) }
        for _ in 0..<200 { if await source.reads > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let started = await source.reads; XCTAssertGreaterThan(started, 0)
        SMBStreamLoader.cancel(in: asset); load.cancel()
        for _ in 0..<200 { if await source.cancellations > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let cancellations = await source.cancellations; XCTAssertGreaterThan(cancellations, 0)
        _ = await load.value
    }
}

private actor CancellableSMBFixture: SMBRangeSource {
    private(set) var reads = 0
    private(set) var cancellations = 0
    func fileSize(at path: String) async throws -> Int64 { 64 * 1024 * 1024 }
    func readRange(at path: String, offset: UInt64, length: Int) async throws -> Data {
        reads += 1
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancellations += 1; throw error }
        return Data(count: length)
    }
}
