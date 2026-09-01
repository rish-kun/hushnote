import Foundation
import CoreGraphics
import XCTest
@testable import Hushnote

final class MeetingScreenshotTests: XCTestCase {
    private struct AllowScreenRecording: ScreenRecordingPermissionAuthorizing {
        func hasScreenRecordingAccess() async -> Bool { true }
        func requestScreenRecordingAccess() async -> Bool { true }
        func openScreenRecordingSettings() {}
    }

    private struct FakeImageProvider: ScreenCaptureImageProviding {
        let image: CGImage
        let displayID: UInt32

        func captureImage() async throws -> ScreenCaptureImage {
            ScreenCaptureImage(image: image, displayID: displayID)
        }
    }

    private func testImage() -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    func testServiceStagesPNGAndReturnsMeetingTimelineMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hushnote-screenshot-service-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let request = MeetingScreenshotRequest(
            id: UUID(),
            meetingID: meetingID,
            recordingSessionID: UUID(),
            timelineMilliseconds: 8_500,
            capturedAt: Date(timeIntervalSince1970: 123)
        )
        let service = MeetingScreenshotService(
            applicationDataURL: root,
            imageProvider: FakeImageProvider(image: testImage(), displayID: 77),
            permission: AllowScreenRecording()
        )

        let result = try await service.capture(request)
        XCTAssertEqual(result.screenshot.meetingID, meetingID)
        XCTAssertEqual(result.screenshot.timelineMilliseconds, 8_500)
        XCTAssertEqual(result.screenshot.displayID, 77)
        XCTAssertEqual(result.screenshot.pixelWidth, 2)
        XCTAssertEqual(result.screenshot.pixelHeight, 2)
        XCTAssertTrue(result.screenshot.relativeFilePath.hasPrefix("Screenshots/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: result.fileURL).prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testDisplaySelectionUsesPointerThenMainDisplayThenFirstDisplay() {
        let displays = [
            ScreenshotDisplayDescriptor(id: 10, frame: CGRect(x: 0, y: 0, width: 500, height: 400)),
            ScreenshotDisplayDescriptor(id: 20, frame: CGRect(x: 500, y: 0, width: 500, height: 400))
        ]

        XCTAssertEqual(
            ScreenshotDisplaySelection.displayID(
                containing: CGPoint(x: 700, y: 200), among: displays, fallbackID: 10
            ),
            20
        )
        XCTAssertEqual(
            ScreenshotDisplaySelection.displayID(
                containing: CGPoint(x: 1_500, y: 200), among: displays, fallbackID: 10
            ),
            10
        )
        XCTAssertEqual(
            ScreenshotDisplaySelection.displayID(
                containing: CGPoint(x: 1_500, y: 200), among: displays, fallbackID: 99
            ),
            10
        )
        XCTAssertNil(
            ScreenshotDisplaySelection.displayID(
                containing: .zero, among: [], fallbackID: 10
            )
        )
    }

    func testOrphanCleanupPreservesRegisteredFilesAndRemovesUntrackedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hushnote-screenshot-orphan-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Screenshots/meeting")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let retained = directory.appending(path: "retained.png")
        let orphan = directory.appending(path: "orphan.png")
        let staged = directory.appending(path: ".interrupted.png")
        try Data("retained".utf8).write(to: retained)
        try Data("orphan".utf8).write(to: orphan)
        try Data("staged".utf8).write(to: staged)

        let service = MeetingScreenshotService(
            applicationDataURL: root,
            imageProvider: FakeImageProvider(image: testImage(), displayID: 1),
            permission: AllowScreenRecording()
        )
        try await service.removeOrphanedFiles(
            referencedRelativePaths: ["Screenshots/meeting/retained.png"]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testScreenshotRoundTripsAndDeletesBytesBeforeMeetingGraph() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hushnote-screenshot-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try MeetingStore(inMemory: (), applicationDataURL: root)
        let meeting = Meeting(title: "Screenshot meeting")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 100),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        try await store.saveRecordingSession(session)

        let screenshot = MeetingScreenshot(
            meetingID: meeting.id,
            recordingSessionID: session.id,
            relativeFilePath: "Screenshots/\(meeting.id.uuidString)/shot.png",
            timelineMilliseconds: 2_500,
            capturedAt: Date(timeIntervalSince1970: 102),
            displayID: 42,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let fileURL = root.appending(path: screenshot.relativeFilePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("png".utf8).write(to: fileURL)
        try await store.saveMeetingScreenshot(screenshot)

        let saved = try await store.meetingScreenshot(id: screenshot.id)
        let meetingScreenshots = try await store.meetingScreenshots(meetingID: meeting.id)
        let sessionScreenshots = try await store.meetingScreenshots(recordingSessionID: session.id)
        XCTAssertEqual(saved, screenshot)
        XCTAssertEqual(meetingScreenshots, [screenshot])
        XCTAssertEqual(sessionScreenshots, [screenshot])

        try await store.deleteMeeting(id: meeting.id, deleteAudioFiles: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let deleted = try await store.meetingScreenshot(id: screenshot.id)
        XCTAssertNil(deleted)
    }

    func testScreenshotRejectsPathTraversalAndCrossMeetingSession() async throws {
        let store = try MeetingStore(inMemory: ())
        let first = Meeting(title: "First")
        let second = Meeting(title: "Second")
        try await store.saveMeeting(first)
        try await store.saveMeeting(second)
        let session = RecordingSession(
            meetingID: first.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        try await store.saveRecordingSession(session)

        do {
            try await store.saveMeetingScreenshot(.init(
                meetingID: first.id,
                relativeFilePath: "Screenshots/../outside.png",
                timelineMilliseconds: 0,
                displayID: 1,
                pixelWidth: 1,
                pixelHeight: 1
            ))
            XCTFail("Expected path traversal to be rejected")
        } catch let error as Hushnote.PersistenceError {
            guard case .invalidScreenshot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            try await store.saveMeetingScreenshot(.init(
                meetingID: second.id,
                recordingSessionID: session.id,
                relativeFilePath: "Screenshots/\(second.id.uuidString)/shot.png",
                timelineMilliseconds: 0,
                displayID: 1,
                pixelWidth: 1,
                pixelHeight: 1
            ))
            XCTFail("Expected cross-meeting session to be rejected")
        } catch let error as Hushnote.PersistenceError {
            guard case .invalidScreenshot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
