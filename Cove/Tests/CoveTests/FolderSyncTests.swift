import XCTest
import SwiftData
@testable import Cove

@MainActor
final class FolderSyncTests: XCTestCase {
    private var containers: [ModelContainer] = []

    private func context() throws -> ModelContext {
        let c = try ModelContainer(
            for: BookmarkSite.self, FavoriteVideo.self, ReadingHistory.self, OfflineItem.self, NASConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(c)
        return ModelContext(c)
    }

    func testPayloadPreservesNASUUIDsAndExcludesPasswords() throws {
        let ctx = try context()
        let nas = NASConfig(name: "HomeNAS", host: "192.168.1.10", port: 445, username: "alice", shareName: "media")
        NASKeychain.save(password: "super-secret-password", for: nas.id)
        defer { NASKeychain.delete(for: nas.id) }

        ctx.insert(nas)
        ctx.insert(BookmarkSite(name: "站点", urlString: "https://media.example/"))
        try ctx.save()

        let data = try CoveSyncPayload.encode(try CoveSyncPayload.snapshot(from: ctx))
        let jsonString = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(jsonString.contains("super-secret-password"))
        XCTAssertTrue(jsonString.contains(nas.id.uuidString))

        let targetCtx = try context()
        try CoveSyncPayload.merge(try CoveSyncPayload.decode(data), into: targetCtx)
        let importedNAS = try targetCtx.fetch(FetchDescriptor<NASConfig>())
        XCTAssertEqual(importedNAS.first?.id, nas.id)
        XCTAssertEqual(try targetCtx.fetchCount(FetchDescriptor<BookmarkSite>()), 1)
    }

    func testMergeResolvesHistoryByLatestTimestamp() throws {
        let ctx = try context()
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)

        let local = ReadingHistory(title: "Local", url: "https://media.example/v/1", fileType: .video, progress: 12)
        local.lastReadAt = oldDate
        ctx.insert(local); try ctx.save()

        var payload = CoveSyncPayload()
        payload.histories.append(.init(
            id: UUID(), title: "Remote Newer", url: "https://media.example/v/1", filePath: nil,
            fileType: .video, progress: 88, lastReadAt: newDate, thumbnailURLString: nil,
            definitionID: nil, nasConfigID: nil
        ))
        try CoveSyncPayload.merge(payload, into: ctx)

        let histories = try ctx.fetch(FetchDescriptor<ReadingHistory>())
        XCTAssertEqual(histories.count, 1)
        XCTAssertEqual(histories.first?.progress, 88)
        XCTAssertEqual(histories.first?.title, "Remote Newer")
    }
}
