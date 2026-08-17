import Foundation

/// Checks that a run did not leave the transcript in a database Hushnote does
/// not own.
///
/// opencode records every conversation into `~/.local/share/opencode/opencode.db`
/// — 1.7 GB on this machine — and offers no way to turn that off. `OPENCODE_DB`
/// moves it, but that variable is undocumented and could stop working in any
/// release. So the redirect is verified rather than trusted: a marker is put in
/// the prompt and looked for afterwards in whatever the shared files grew by.
public struct SharedDatabaseWitness: Sendable {
    public struct Fingerprint: Sendable, Equatable {
        public let size: UInt64
        public let modified: Date?
    }

    /// Only regions written during the run are read back, so this stays cheap
    /// against a multi-gigabyte file. A run that somehow rewrote the whole
    /// database from the start is reported rather than scanned.
    static let maximumScanBytes: UInt64 = 64 * 1_024 * 1_024

    public let files: [URL]

    public init(files: [URL]) {
        self.files = files
    }

    /// The shared files opencode uses by default, including the write-ahead log
    /// where a fresh write actually lands first.
    public static func opencodeDefault() -> SharedDatabaseWitness {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode", directoryHint: .isDirectory)
        return SharedDatabaseWitness(files: [
            directory.appending(path: "opencode.db"),
            directory.appending(path: "opencode.db-wal")
        ])
    }

    public func snapshot() -> [URL: Fingerprint] {
        var result: [URL: Fingerprint] = [:]
        for file in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            else { continue }
            result[file] = Fingerprint(
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: attributes[.modificationDate] as? Date
            )
        }
        return result
    }

    /// The file the marker turned up in, or nil when the redirect held.
    public func leak(of marker: String, since previous: [URL: Fingerprint]) -> URL? {
        let needle = Data(marker.utf8)
        for file in files {
            let before = previous[file]
            guard let after = snapshotOne(file), after != before else { continue }
            let from = (after.size > (before?.size ?? 0)) ? (before?.size ?? 0) : 0
            guard after.size - from <= Self.maximumScanBytes else { return file }
            if contains(needle, in: file, from: from) { return file }
        }
        return nil
    }

    private func snapshotOne(_ file: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        else { return nil }
        return Fingerprint(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date
        )
    }

    private func contains(_ needle: Data, in file: URL, from offset: UInt64) -> Bool {
        guard !needle.isEmpty, let handle = try? FileHandle(forReadingFrom: file) else {
            return false
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var carry = Data()
        let chunkSize = 4 * 1_024 * 1_024
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var window = carry
            window.append(chunk)
            if window.range(of: needle) != nil { return true }
            // Keep enough of the tail that a marker split across two reads is
            // still found.
            carry = window.suffix(needle.count - 1)
        }
        return false
    }
}
