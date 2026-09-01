import Darwin
import Foundation

/// A speech model directory whose on-disk cost should be shown in Settings.
struct ModelStorageScanLocation: Equatable, Sendable {
    var modelID: String
    var displayName: String
    var url: URL
}

/// One meeting's retained or recoverable recording directory.
struct RecordingStorageLocation: Equatable, Sendable {
    var meetingID: UUID
    var title: String
    var url: URL
}

/// Everything the storage screen currently knows how to account for.
struct StorageScanRequest: Equatable, Sendable {
    var models: [ModelStorageScanLocation] = []
    var recordings: [RecordingStorageLocation] = []
    /// Main SQLite files. Existing `-wal` and `-shm` sidecars are discovered
    /// at scan time because either can appear or disappear while the app runs.
    var databaseURLs: [URL] = []
    /// The app-owned root whose unclaimed contents are reported as Other.
    var applicationDataURL: URL? = nil
}

enum StorageCategory: String, Equatable, Sendable {
    case models
    case recordings
    case database
    case other
}

/// A path that could not be fully inspected. A report remains useful when it
/// has issues: the sizes it did observe are still returned, marked partial.
struct StorageScanIssue: Equatable, Sendable {
    var category: StorageCategory
    var itemID: String
    var url: URL
    var message: String
}

struct ModelStorageUsage: Equatable, Sendable {
    var modelID: String
    var displayName: String
    var url: URL
    var allocatedBytes: Int64
    var isPartial: Bool
}

struct RecordingStorageUsage: Equatable, Sendable {
    var meetingID: UUID
    var title: String
    var url: URL
    var allocatedBytes: Int64
    var isPartial: Bool
}

struct DatabaseStorageUsage: Equatable, Sendable {
    var databaseURL: URL
    var files: [URL]
    var allocatedBytes: Int64
    var isPartial: Bool
}

/// The roll-up used by storage cards without making the UI re-sum details.
struct StorageCategoryUsage: Equatable, Sendable {
    var allocatedBytes: Int64
    var itemCount: Int
    var partialItemCount: Int

    var isPartial: Bool { partialItemCount > 0 }
}

struct StorageReport: Equatable, Sendable {
    var models: StorageCategoryUsage
    var recordings: StorageCategoryUsage
    var database: StorageCategoryUsage
    var other: StorageCategoryUsage
    var modelDetails: [ModelStorageUsage]
    var recordingDetails: [RecordingStorageUsage]
    var databaseDetails: [DatabaseStorageUsage]
    var issues: [StorageScanIssue]

    var totalAllocatedBytes: Int64 {
        models.allocatedBytes
            + recordings.allocatedBytes
            + database.allocatedBytes
            + other.allocatedBytes
    }

    var isPartial: Bool { !issues.isEmpty }
}

/// Recovery audio is the only copy of an interrupted meeting. Cleanup is
/// intentionally limited to completed meetings and never targets the active
/// meeting. A different completed meeting remains safe to clean while capture
/// owns its own session directory.
enum RecordingStorageCleanupPolicy {
    static func canRemove(
        meetingID: UUID,
        status: MeetingStatus,
        activeMeetingID: UUID?,
        recordingPhase: RecordingPhase
    ) -> Bool {
        status == .ready && meetingID != activeMeetingID
    }
}

/// Injection boundary for the coordinator and for previews/tests that should
/// not enumerate a person's real model or recording directories.
protocol StorageAccounting: Sendable {
    func report(for request: StorageScanRequest) async throws -> StorageReport
}

/// Counts filesystem allocation rather than logical file length, so sparse and
/// compressed files do not make the storage screen claim space they do not use.
/// Work is detached from the caller because a large model cache can contain
/// thousands of artifacts and filesystem enumeration must never block SwiftUI.
struct StorageAccountingService: StorageAccounting {
    func report(for request: StorageScanRequest) async throws -> StorageReport {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try Self.scan(request)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct FileIdentity: Hashable {
        var device: UInt64
        var inode: UInt64
    }

    private enum TargetKind {
        case model(ModelStorageScanLocation, originalIndex: Int)
        case recording(RecordingStorageLocation, originalIndex: Int)
        case database(URL, databaseURL: URL, originalIndex: Int)
        case other(URL)

        var category: StorageCategory {
            switch self {
            case .model: .models
            case .recording: .recordings
            case .database: .database
            case .other: .other
            }
        }

        var itemID: String {
            switch self {
            case .model(let location, _): location.modelID
            case .recording(let location, _): location.meetingID.uuidString
            case .database(_, let databaseURL, _): databaseURL.path
            case .other: "application-data"
            }
        }

        var url: URL {
            switch self {
            case .model(let location, _): location.url
            case .recording(let location, _): location.url
            case .database(let url, _, _), .other(let url): url
            }
        }

        var originalIndex: Int {
            switch self {
            case .model(_, let index), .recording(_, let index): index
            case .database(_, _, let index): index
            case .other: 0
            }
        }
    }

    private struct TargetResult {
        var target: TargetKind
        var allocatedBytes: Int64
        var issues: [StorageScanIssue]
    }

    private static func scan(_ request: StorageScanRequest) throws -> StorageReport {
        try Task.checkCancellation()
        var targets: [TargetKind] = request.models.enumerated().map {
            .model($0.element, originalIndex: $0.offset)
        }
        targets.append(contentsOf: request.recordings.enumerated().map {
            .recording($0.element, originalIndex: $0.offset)
        })
        for (index, rawDatabaseURL) in request.databaseURLs.enumerated() {
            let databaseURL = rawDatabaseURL.standardizedFileURL
            targets.append(.database(databaseURL, databaseURL: databaseURL, originalIndex: index))
            for sidecar in existingSQLiteSidecars(for: databaseURL) {
                targets.append(.database(sidecar, databaseURL: databaseURL, originalIndex: index))
            }
        }
        if let applicationDataURL = request.applicationDataURL {
            targets.append(.other(applicationDataURL))
        }

        // A specific item owns its files before an accidentally supplied parent
        // root gets a chance to see them. Exact duplicate roots remain stable.
        targets.sort {
            let leftDepth = $0.url.standardizedFileURL.pathComponents.count
            let rightDepth = $1.url.standardizedFileURL.pathComponents.count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            return $0.originalIndex < $1.originalIndex
        }

        var seen = Set<FileIdentity>()
        var results: [TargetResult] = []
        for target in targets {
            try Task.checkCancellation()
            results.append(try scan(target, seen: &seen))
        }

        let modelResults = results.compactMap { result -> (ModelStorageScanLocation, Int, TargetResult)? in
            guard case .model(let location, let index) = result.target else { return nil }
            return (location, index, result)
        }.sorted { $0.1 < $1.1 }
        let recordingResults = results.compactMap { result -> (RecordingStorageLocation, Int, TargetResult)? in
            guard case .recording(let location, let index) = result.target else { return nil }
            return (location, index, result)
        }.sorted { $0.1 < $1.1 }
        let groupedDatabaseResults = Dictionary(grouping: results.compactMap { result -> (URL, Int, TargetResult)? in
            guard case .database(_, let databaseURL, let index) = result.target else { return nil }
            return (databaseURL, index, result)
        }, by: { $0.0 })
        let databaseResults = groupedDatabaseResults.map { databaseURL, members in
            (
                databaseURL,
                members.map(\.1).min() ?? 0,
                members.map(\.2)
            )
        }.sorted { $0.1 < $1.1 }
        let otherResults = results.filter { $0.target.category == .other }

        let modelDetails = modelResults.map { location, _, result in
            ModelStorageUsage(
                modelID: location.modelID,
                displayName: location.displayName,
                url: location.url,
                allocatedBytes: result.allocatedBytes,
                isPartial: !result.issues.isEmpty
            )
        }
        let recordingDetails = recordingResults.map { location, _, result in
            RecordingStorageUsage(
                meetingID: location.meetingID,
                title: location.title,
                url: location.url,
                allocatedBytes: result.allocatedBytes,
                isPartial: !result.issues.isEmpty
            )
        }
        let databaseDetails = databaseResults.map { databaseURL, _, members in
            DatabaseStorageUsage(
                databaseURL: databaseURL,
                files: members.map(\.target.url).sorted { $0.path < $1.path },
                allocatedBytes: members.reduce(0) { $0 + $1.allocatedBytes },
                isPartial: members.contains { !$0.issues.isEmpty }
            )
        }
        let issues = results.flatMap(\.issues)

        return StorageReport(
            models: categoryUsage(modelDetails.map { ($0.allocatedBytes, $0.isPartial) }),
            recordings: categoryUsage(recordingDetails.map { ($0.allocatedBytes, $0.isPartial) }),
            database: categoryUsage(databaseDetails.map { ($0.allocatedBytes, $0.isPartial) }),
            other: categoryUsage(otherResults.map { ($0.allocatedBytes, !$0.issues.isEmpty) }),
            modelDetails: modelDetails,
            recordingDetails: recordingDetails,
            databaseDetails: databaseDetails,
            issues: issues
        )
    }

    private static func existingSQLiteSidecars(for databaseURL: URL) -> [URL] {
        ["-wal", "-shm"].compactMap { suffix in
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            var metadata = stat()
            return lstat(url.path, &metadata) == 0 ? url : nil
        }
    }

    private static func categoryUsage(_ items: [(bytes: Int64, partial: Bool)]) -> StorageCategoryUsage {
        StorageCategoryUsage(
            allocatedBytes: items.reduce(0) { $0 + $1.bytes },
            itemCount: items.count,
            partialItemCount: items.count(where: \.partial)
        )
    }

    private static func scan(_ target: TargetKind, seen: inout Set<FileIdentity>) throws -> TargetResult {
        let manager = FileManager()
        let root = target.url.standardizedFileURL
        var issues: [StorageScanIssue] = []
        var allocatedBytes: Int64 = 0

        func record(_ error: any Error, at url: URL) {
            issues.append(StorageScanIssue(
                category: target.category,
                itemID: target.itemID,
                url: url,
                message: error.localizedDescription
            ))
        }

        do {
            let rootKind = try inspect(root, seen: &seen, allocatedBytes: &allocatedBytes)
            // A root supplied as a symbolic link is a valid zero-byte target,
            // not permission to walk the destination outside the request.
            if rootKind == S_IFLNK {
                return TargetResult(target: target, allocatedBytes: 0, issues: [])
            }
        } catch {
            record(error, at: root)
            return TargetResult(target: target, allocatedBytes: allocatedBytes, issues: issues)
        }

        var enumerationErrors: [(URL, any Error)] = []
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                enumerationErrors.append((url, error))
                return true
            }
        ) else {
            // A regular file is a complete one-item target. A directory that
            // cannot produce an enumerator is partial and should say why.
            var metadata = stat()
            if lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR {
                record(StorageScanFailure.couldNotEnumerate, at: root)
            }
            return TargetResult(target: target, allocatedBytes: allocatedBytes, issues: issues)
        }

        for case let child as URL in enumerator {
            try Task.checkCancellation()
            do {
                let kind = try inspect(child, seen: &seen, allocatedBytes: &allocatedBytes)
                if kind == S_IFLNK { enumerator.skipDescendants() }
            } catch {
                record(error, at: child)
                enumerator.skipDescendants()
            }
        }
        for (url, error) in enumerationErrors { record(error, at: url) }
        return TargetResult(target: target, allocatedBytes: allocatedBytes, issues: issues)
    }

    /// Returns the POSIX file kind so callers can prune symbolic-link entries.
    @discardableResult
    private static func inspect(
        _ url: URL,
        seen: inout Set<FileIdentity>,
        allocatedBytes: inout Int64
    ) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind = metadata.st_mode & S_IFMT
        guard kind != S_IFLNK, kind == S_IFREG else { return kind }
        let identity = FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
        if seen.insert(identity).inserted {
            allocatedBytes += Int64(metadata.st_blocks) * 512
        }
        return kind
    }
}

private enum StorageScanFailure: LocalizedError {
    case couldNotEnumerate

    var errorDescription: String? {
        "The directory could not be enumerated."
    }
}
