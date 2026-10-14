import XCTest
import AVFoundation
import UIKit
@testable import Cove

@MainActor final class AudioMetadataTests: XCTestCase {
    private func tag(_ key: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem(); item.identifier = key; item.value = value
        return item
    }
    private func item(_ title: String, artwork: Data? = nil) throws -> AVPlayerItem {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tone", withExtension: "opus", subdirectory: "Audio"))
        let item = AVPlayerItem(url: url)
        item.externalMetadata = [tag(.commonIdentifierTitle, title as NSString), tag(.commonIdentifierArtist, "测试音乐人" as NSString), tag(.commonIdentifierAlbumName, "测试专辑" as NSString)]
        if let artwork { item.externalMetadata.append(tag(.commonIdentifierArtwork, artwork as NSData)) }
        return item
    }
    func testReadsTitleArtistAlbumAndBoundsArtwork() async throws {
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.pngData()!
        let value = await AudioTrackMetadata.read(try item("测试曲目", artwork: cover).externalMetadata)
        XCTAssertEqual(value.title, "测试曲目"); XCTAssertEqual(value.artist, "测试音乐人")
        XCTAssertEqual(value.album, "测试专辑"); XCTAssertEqual(value.artwork, cover)
        let tooLarge = await AudioTrackMetadata.read([tag(.commonIdentifierArtwork, Data(count: 4 * 1024 * 1024 + 1) as NSData)])
        XCTAssertNil(tooLarge.artwork)
    }
    func testSwitchAndStopDoNotKeepPreviousMetadata() async throws {
        let manager = AudioPlayerManager.shared; defer { manager.stop() }
        manager.play(item: try item("上一首", artwork: Data([1,2,3])), name: "first", path: "/first.opus")
        manager.player?.volume = 0
        manager.play(item: try item("下一首"), name: "second", path: "/second.opus")
        manager.player?.volume = 0
        for _ in 0..<40 where manager.title != "下一首" { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(manager.title, "下一首"); XCTAssertNil(manager.artwork)
        manager.stop()
        XCTAssertTrue(manager.title.isEmpty); XCTAssertTrue(manager.artist.isEmpty)
        XCTAssertTrue(manager.album.isEmpty); XCTAssertNil(manager.artwork)
        try await Task.sleep(for: .milliseconds(50)); XCTAssertTrue(manager.title.isEmpty)
    }
    func testMissingMetadataKeepsFilenameFallback() async {
        let value = await AudioTrackMetadata.read([])
        XCTAssertTrue(value.title.isEmpty); XCTAssertTrue(value.artist.isEmpty); XCTAssertNil(value.artwork)
    }
}
