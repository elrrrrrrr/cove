import XCTest
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers
import SwiftUI
@testable import Cove

@MainActor final class OpusAudioTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tone", withExtension: "opus", subdirectory: "Audio"))
    }

    func testOpusRecognitionAcrossNASAndWebAddresses() {
        XCTAssertEqual(FileTypeDetector.detect(fromPath: "/音乐/声音.OPUS"), .audio)
        XCTAssertEqual(FileTypeDetector.detect(from: URL(string: "https://media.example/audio.opus?token=fixture")!), .audio)
        XCTAssertEqual(NASFileEntry(name: "声音.opus", path: "/声音.opus", isDirectory: false, size: 100, modifiedAt: nil).fileType, .audio)
        XCTAssertTrue(UTType(filenameExtension: "opus")?.conforms(to: .audio) == true)
    }

    func testLocalOpusDecodesToPCM() async throws {
        let asset = AVURLAsset(url: try fixture())
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(frames, 96_000)
    }

    func testLocalAudioViewStartsOpusPlayback() async throws {
        let url = try fixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            NASAudioView(trackName: "Opus 离线样本", trackPath: url.path, fileURL: url))
        window.makeKeyAndVisible()
        let manager = AudioPlayerManager.shared
        defer { manager.stop(); window.isHidden = true; previous?.makeKey() }
        for _ in 0..<80 {
            manager.player?.volume = 0
            if manager.trackPath == url.path, manager.player?.currentItem?.status == .readyToPlay, manager.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        manager.player?.volume = 0
        XCTAssertEqual(manager.trackPath, url.path)
        XCTAssertEqual(manager.player?.currentItem?.status, .readyToPlay)
        XCTAssertGreaterThan(manager.duration, 0)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let screenshot = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOpusRangeStreamPlaysPausesAndSeeks() async throws {
        let source = OpusRangeFixture(data: try Data(contentsOf: fixture()))
        let item = SMBStreamLoader.makePlayerItem(client: source, remotePath: "/声音.opus")
        let manager = AudioPlayerManager.shared
        defer { manager.stop() }
        manager.play(item: item, name: "声音", path: "/声音.opus")
        let player = try XCTUnwrap(manager.player)
        player.volume = 0
        for _ in 0..<160 {
            if item.status == .failed || player.currentTime().seconds > 0.1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(item.status, .readyToPlay, String(describing: item.error))
        XCTAssertGreaterThan(player.currentTime().seconds, 0.1)
        manager.togglePlay()
        XCTAssertFalse(manager.isPlaying)
        manager.seek(to: 1)
        for _ in 0..<80 {
            if abs(player.currentTime().seconds - 1) < 0.15 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(player.currentTime().seconds, 1, accuracy: 0.15)
        manager.togglePlay()
        XCTAssertTrue(manager.isPlaying)
        let lengths = await source.readLengths
        XCTAssertFalse(lengths.isEmpty)
        XCTAssertTrue(lengths.allSatisfy { $0 > 0 && $0 <= SMBFileRead.chunkBytes })
    }
}

private actor OpusRangeFixture: SMBRangeSource {
    let data: Data
    var readLengths: [Int] = []
    init(data: Data) { self.data = data }
    func fileSize(at path: String) async throws -> Int64 { Int64(data.count) }
    func readRange(at path: String, offset: UInt64, length: Int) async throws -> Data {
        readLengths.append(length)
        guard offset < data.count else { return Data() }
        return data.subdata(in: Int(offset)..<min(Int(offset) + length, data.count))
    }
}
