import Foundation
import AVFoundation
import XCTest
@testable import Hushnote

/// A recovery CAF is the only copy of a meeting's audio. These tests pin the
/// rule that capture may never open a take that already holds recorded frames.
final class RecoveryTakeTests: XCTestCase {
    private var directory = URL(filePath: "/")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func writeTake(named name: String, frames: AVAudioFrameCount) throws -> URL {
        let url = directory.appending(path: name)
        let writer = try IncrementalCAFWriter(url: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = 0.1
        }
        _ = try writer.append(buffer)
        writer.finish()
        return url
    }

    func testWriterRefusesToOpenATakeThatAlreadyHoldsAudio() throws {
        let url = try writeTake(named: "system-0.caf", frames: 48_000)
        let framesBefore = try AVAudioFile(forReading: url).length
        XCTAssertEqual(framesBefore, 48_000, "fixture should hold one second of audio")

        XCTAssertThrowsError(try IncrementalCAFWriter(url: url)) { error in
            guard case AudioPipelineError.writerFailed = error else {
                return XCTFail("expected .writerFailed, got \(error)")
            }
        }

        XCTAssertEqual(
            try AVAudioFile(forReading: url).length,
            framesBefore,
            "the existing recording must survive a refused open"
        )
    }

    func testAllocatesAFreshTakeWhenOneAlreadyHoldsAudio() throws {
        let first = try AudioPipeline.allocateTakeURL(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        try writeTake(named: first.lastPathComponent, frames: 4_800)

        let second = try AudioPipeline.allocateTakeURL(in: directory)

        XCTAssertNotEqual(second, first, "a retry must not reuse the previous take")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            try AVAudioFile(forReading: first).length,
            4_800,
            "allocating the next take must not disturb the previous one"
        )
    }

    func testRecoveryPrefersTheLongestTake() throws {
        try writeTake(named: "system-0.caf", frames: 4_800)
        try writeTake(named: "system-1.caf", frames: 96_000)
        try writeTake(named: "system-2.caf", frames: 9_600)

        XCTAssertEqual(
            AudioPipeline.longestTake(in: directory)?.lastPathComponent,
            "system-1.caf"
        )
    }

    func testRecoveryStillFindsTheLegacyTakeName() throws {
        try writeTake(named: "system.caf", frames: 4_800)

        XCTAssertEqual(
            AudioPipeline.longestTake(in: directory)?.lastPathComponent,
            "system.caf"
        )
    }

    func testLongestTakeIsNilWhenTheDirectoryHoldsNoAudio() {
        XCTAssertNil(AudioPipeline.longestTake(in: directory))
    }
}
