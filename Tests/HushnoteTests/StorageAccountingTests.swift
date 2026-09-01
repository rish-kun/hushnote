import Foundation
import Testing
@testable import Hushnote

@Suite("Storage accounting")
struct StorageAccountingTests {
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Models and recordings are reported separately with allocated sizes")
    func categoriesAndDetails() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appending(path: "model", directoryHint: .isDirectory)
        let recording = root.appending(path: "recording", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128 * 1_024).write(to: model.appending(path: "weights.bin"))
        try Data(repeating: 2, count: 64 * 1_024).write(to: recording.appending(path: "system.caf"))
        let meetingID = UUID()

        let report = try await StorageAccountingService().report(for: StorageScanRequest(
            models: [.init(modelID: "small", displayName: "Small", url: model)],
            recordings: [.init(meetingID: meetingID, title: "Planning", url: recording)]
        ))

        #expect(report.models.itemCount == 1)
        #expect(report.recordings.itemCount == 1)
        #expect(report.database.itemCount == 0)
        #expect(report.other.itemCount == 0)
        #expect(report.models.allocatedBytes > 0)
        #expect(report.recordings.allocatedBytes > 0)
        #expect(report.modelDetails.first?.modelID == "small")
        #expect(report.recordingDetails.first?.meetingID == meetingID)
        #expect(report.totalAllocatedBytes == report.models.allocatedBytes + report.recordings.allocatedBytes)
        #expect(report.isPartial == false)
    }

    @Test("Database sidecars are discovered and Other gets only unclaimed app data")
    func databaseSidecarsAndOther() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "hushnote.sqlite")
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let shm = URL(fileURLWithPath: database.path + "-shm")
        let other = root.appending(path: "preferences-cache.bin")
        try Data(repeating: 1, count: 64 * 1_024).write(to: database)
        try Data(repeating: 2, count: 32 * 1_024).write(to: wal)
        try Data(repeating: 3, count: 16 * 1_024).write(to: shm)
        try Data(repeating: 4, count: 48 * 1_024).write(to: other)

        let databaseOnly = try await StorageAccountingService().report(for: StorageScanRequest(
            databaseURLs: [database]
        ))
        let report = try await StorageAccountingService().report(for: StorageScanRequest(
            databaseURLs: [database],
            applicationDataURL: root
        ))

        #expect(report.database.itemCount == 1)
        #expect(report.database.allocatedBytes == databaseOnly.totalAllocatedBytes)
        #expect(report.databaseDetails.first?.files == [shm, wal, database].sorted { $0.path < $1.path })
        #expect(report.other.itemCount == 1)
        #expect(report.other.allocatedBytes > 0)
        #expect(report.totalAllocatedBytes == report.database.allocatedBytes + report.other.allocatedBytes)
    }

    @Test("A recording below Application Support is excluded from Other")
    func recordingIsExcludedFromOther() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appending(path: "RecoveryAudio/meeting", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 80 * 1_024).write(to: recording.appending(path: "system.caf"))

        let report = try await StorageAccountingService().report(for: StorageScanRequest(
            recordings: [.init(meetingID: UUID(), title: "Call", url: recording)],
            applicationDataURL: root
        ))

        #expect(report.recordings.allocatedBytes > 0)
        #expect(report.other.allocatedBytes == 0)
        #expect(report.totalAllocatedBytes == report.recordings.allocatedBytes)
    }

    @Test("Overlapping roots never count the same allocated blocks twice")
    func overlappingRootsAreDeduplicated() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appending(path: "specific-model", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 96 * 1_024).write(to: child.appending(path: "weights.bin"))

        let childOnly = try await StorageAccountingService().report(for: StorageScanRequest(
            models: [.init(modelID: "specific", displayName: "Specific", url: child)]
        ))
        let overlapping = try await StorageAccountingService().report(for: StorageScanRequest(
            models: [
                .init(modelID: "cache", displayName: "Cache", url: root),
                .init(modelID: "specific", displayName: "Specific", url: child),
            ]
        ))

        #expect(overlapping.totalAllocatedBytes == childOnly.totalAllocatedBytes)
        #expect(overlapping.modelDetails.first(where: { $0.modelID == "specific" })?.allocatedBytes == childOnly.totalAllocatedBytes)
        #expect(overlapping.modelDetails.first(where: { $0.modelID == "cache" })?.allocatedBytes == 0)
    }

    @Test("Symbolic links are neither followed nor counted")
    func symbolicLinksAreSkipped() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let payload = outside.appending(path: "large.bin")
        try Data(repeating: 4, count: 160 * 1_024).write(to: payload)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.bin"),
            withDestinationURL: payload
        )

        let report = try await StorageAccountingService().report(for: StorageScanRequest(
            models: [.init(modelID: "linked", displayName: "Linked", url: root)]
        ))

        #expect(report.totalAllocatedBytes == 0)
        #expect(report.isPartial == false)
    }

    @Test("A missing target produces a useful partial report")
    func inaccessibleTargetIsPartial() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appending(path: "not-there")

        let report = try await StorageAccountingService().report(for: StorageScanRequest(
            recordings: [.init(meetingID: UUID(), title: "Missing", url: missing)]
        ))

        #expect(report.totalAllocatedBytes == 0)
        #expect(report.isPartial)
        #expect(report.recordings.isPartial)
        #expect(report.recordings.partialItemCount == 1)
        #expect(report.recordingDetails.first?.isPartial == true)
        #expect(report.issues.count == 1)
        #expect(report.issues.first?.url == missing)
    }

    @Test("A cancelled scan throws cancellation instead of returning a complete-looking report")
    func cancellationPropagates() async {
        let task = Task {
            try await StorageAccountingService().report(for: StorageScanRequest())
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("Only completed inactive meetings allow recording cleanup")
    func recordingCleanupPolicy() {
        let meetingID = UUID()

        #expect(RecordingStorageCleanupPolicy.canRemove(
            meetingID: meetingID,
            status: .ready,
            activeMeetingID: nil,
            recordingPhase: .idle
        ))
        #expect(RecordingStorageCleanupPolicy.canRemove(
            meetingID: meetingID,
            status: .ready,
            activeMeetingID: UUID(),
            recordingPhase: .recording
        ))
        #expect(RecordingStorageCleanupPolicy.canRemove(
            meetingID: meetingID,
            status: .interrupted,
            activeMeetingID: nil,
            recordingPhase: .idle
        ) == false)
        #expect(RecordingStorageCleanupPolicy.canRemove(
            meetingID: meetingID,
            status: .ready,
            activeMeetingID: meetingID,
            recordingPhase: .recording
        ) == false)
    }
}
