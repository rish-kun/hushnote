@preconcurrency import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// The context captured at the instant the user presses Snapshot. The caller
/// supplies the meeting-wide media clock; encoding time must not move the
/// screenshot's position on that clock.
struct MeetingScreenshotRequest: Equatable, Sendable {
    var id: UUID
    var meetingID: UUID
    var recordingSessionID: UUID?
    var timelineMilliseconds: Int64
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        meetingID: UUID,
        recordingSessionID: UUID? = nil,
        timelineMilliseconds: Int64,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.recordingSessionID = recordingSessionID
        self.timelineMilliseconds = timelineMilliseconds
        self.capturedAt = capturedAt
    }
}

struct ScreenCaptureImage: Sendable {
    var image: CGImage
    var displayID: UInt32
}

protocol ScreenCaptureImageProviding: Sendable {
    func captureImage() async throws -> ScreenCaptureImage
}

protocol ScreenRecordingPermissionAuthorizing: Sendable {
    func hasScreenRecordingAccess() async -> Bool
    func requestScreenRecordingAccess() async -> Bool
    func openScreenRecordingSettings()
}

struct SystemScreenRecordingPermissionAuthorizer: ScreenRecordingPermissionAuthorizing {
    func hasScreenRecordingAccess() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAccess() async -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
    }
}

enum MeetingScreenshotError: Error, Equatable, LocalizedError, Sendable {
    case permissionDenied
    case noDisplay
    case captureFailed(String)
    case imageEncodingFailed
    case invalidImage
    case fileInstallationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is required to save a snapshot. Open System Settings to allow Hushnote."
        case .noDisplay:
            "No display is available for a snapshot."
        case .captureFailed(let reason):
            "The snapshot could not be captured: \(reason)"
        case .imageEncodingFailed:
            "The snapshot could not be encoded as a PNG."
        case .invalidImage:
            "The snapshot returned an empty image."
        case .fileInstallationFailed(let reason):
            "The snapshot could not be saved: \(reason)"
        }
    }
}

/// The point-to-display decision is pure so multi-display behaviour can be
/// tested without asking ScreenCaptureKit for real content.
struct ScreenshotDisplayDescriptor: Equatable, Sendable {
    var id: UInt32
    var frame: CGRect
}

enum ScreenshotDisplaySelection {
    static func displayID(
        containing point: CGPoint,
        among displays: [ScreenshotDisplayDescriptor],
        fallbackID: UInt32?
    ) -> UInt32? {
        displays.first(where: { $0.frame.contains(point) })?.id
            ?? fallbackID.flatMap { id in displays.contains(where: { $0.id == id }) ? id : nil }
            ?? displays.first?.id
    }
}

/// One-shot ScreenCaptureKit client. It captures the display under the mouse,
/// excludes every window owned by Hushnote, and never creates a stream.
struct ScreenCaptureKitImageProvider: ScreenCaptureImageProviding {
    func captureImage() async throws -> ScreenCaptureImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw MeetingScreenshotError.captureFailed(error.localizedDescription)
        }

        guard !content.displays.isEmpty else { throw MeetingScreenshotError.noDisplay }

        let descriptors = content.displays.map {
            ScreenshotDisplayDescriptor(
                id: $0.displayID,
                frame: Self.frame(for: $0.displayID)
            )
        }
        let fallbackID = CGMainDisplayID()
        guard let selectedID = ScreenshotDisplaySelection.displayID(
            containing: NSEvent.mouseLocation,
            among: descriptors,
            fallbackID: fallbackID
        ), let display = content.displays.first(where: { $0.displayID == selectedID })
        else { throw MeetingScreenshotError.noDisplay }

        let ownApplication = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication.map { [$0] } ?? [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.minimumFrameInterval = .zero

        let image: CGImage
        do {
            image = try await Self.capture(filter: filter, configuration: configuration)
        } catch let error as MeetingScreenshotError {
            throw error
        } catch {
            throw MeetingScreenshotError.captureFailed(error.localizedDescription)
        }
        guard image.width > 0, image.height > 0 else {
            throw MeetingScreenshotError.invalidImage
        }
        return ScreenCaptureImage(image: image, displayID: selectedID)
    }

    private static func frame(for displayID: UInt32) -> CGRect {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { $0.uint32Value == displayID } ?? false
        }?.frame ?? .zero
    }

    private static func capture(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: MeetingScreenshotError.invalidImage)
                }
            }
        }
    }
}

struct MeetingScreenshotCaptureResult: Sendable {
    var screenshot: MeetingScreenshot
    var fileURL: URL
}

/// Encodes one image to a sibling temporary file and promotes it with a single
/// filesystem move. SQLite metadata is intentionally saved by MeetingStore
/// only after this method succeeds.
struct MeetingScreenshotService: Sendable {
    private let imageProvider: any ScreenCaptureImageProviding
    private let permission: any ScreenRecordingPermissionAuthorizing
    private let applicationDataURL: URL

    init(
        applicationDataURL: URL,
        imageProvider: any ScreenCaptureImageProviding = ScreenCaptureKitImageProvider(),
        permission: any ScreenRecordingPermissionAuthorizing = SystemScreenRecordingPermissionAuthorizer()
    ) {
        self.applicationDataURL = applicationDataURL.standardizedFileURL
        self.imageProvider = imageProvider
        self.permission = permission
    }

    func openScreenRecordingSettings() {
        permission.openScreenRecordingSettings()
    }

    /// Removes files that were atomically installed but never registered in
    /// SQLite because the process ended between those two durable operations.
    func removeOrphanedFiles(referencedRelativePaths: Set<String>) async throws {
        let applicationDataURL = applicationDataURL
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let canonicalApplicationDataURL = applicationDataURL.resolvingSymlinksInPath()
            let root = canonicalApplicationDataURL
                .appending(path: "Screenshots", directoryHint: .isDirectory)
            guard manager.fileExists(atPath: root.path) else { return }
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { return }

            while let fileURL = enumerator.nextObject() as? URL {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let canonicalFileURL = fileURL.resolvingSymlinksInPath()
                let rootPrefix = canonicalApplicationDataURL.path.hasSuffix("/")
                    ? canonicalApplicationDataURL.path
                    : canonicalApplicationDataURL.path + "/"
                guard canonicalFileURL.path.hasPrefix(rootPrefix) else { continue }
                let relativePath = String(canonicalFileURL.path.dropFirst(rootPrefix.count))
                guard !referencedRelativePaths.contains(relativePath) else { continue }
                try manager.removeItem(at: canonicalFileURL)
            }
        }.value
    }

    func capture(_ request: MeetingScreenshotRequest) async throws -> MeetingScreenshotCaptureResult {
        guard request.timelineMilliseconds >= 0 else {
            throw MeetingScreenshotError.fileInstallationFailed("the timeline position cannot be negative")
        }
        let hasAccess = await permission.hasScreenRecordingAccess()
        let accessGranted: Bool
        if hasAccess {
            accessGranted = true
        } else {
            accessGranted = await permission.requestScreenRecordingAccess()
        }
        guard accessGranted else {
            throw MeetingScreenshotError.permissionDenied
        }

        let captured = try await imageProvider.captureImage()
        guard captured.image.width > 0, captured.image.height > 0 else {
            throw MeetingScreenshotError.invalidImage
        }

        let relativePath = "Screenshots/\(request.meetingID.uuidString)/\(request.id.uuidString).png"
        let destination = applicationDataURL.appending(path: relativePath)
        let directory = destination.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MeetingScreenshotError.fileInstallationFailed(error.localizedDescription)
        }

        let staged = directory.appending(path: ".\(request.id.uuidString)-\(UUID().uuidString).png")
        defer { try? manager.removeItem(at: staged) }
        do {
            guard let destinationRef = CGImageDestinationCreateWithURL(
                staged as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { throw MeetingScreenshotError.imageEncodingFailed }
            CGImageDestinationAddImage(destinationRef, captured.image, nil)
            guard CGImageDestinationFinalize(destinationRef) else {
                throw MeetingScreenshotError.imageEncodingFailed
            }
            guard manager.fileExists(atPath: staged.path),
                  (try manager.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0 > 0
            else { throw MeetingScreenshotError.imageEncodingFailed }
            if manager.fileExists(atPath: destination.path) {
                throw MeetingScreenshotError.fileInstallationFailed("the snapshot destination already exists")
            }
            try manager.moveItem(at: staged, to: destination)
        } catch let error as MeetingScreenshotError {
            throw error
        } catch {
            throw MeetingScreenshotError.fileInstallationFailed(error.localizedDescription)
        }

        let screenshot = MeetingScreenshot(
            id: request.id,
            meetingID: request.meetingID,
            recordingSessionID: request.recordingSessionID,
            relativeFilePath: relativePath,
            timelineMilliseconds: request.timelineMilliseconds,
            capturedAt: request.capturedAt,
            displayID: captured.displayID,
            pixelWidth: captured.image.width,
            pixelHeight: captured.image.height
        )
        return MeetingScreenshotCaptureResult(screenshot: screenshot, fileURL: destination)
    }
}
