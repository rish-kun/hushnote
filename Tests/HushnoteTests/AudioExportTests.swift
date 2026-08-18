import AVFoundation
import Foundation
import Testing
@testable import Hushnote

/// Exporting the recording is not exporting a transcript. The file is the
/// meeting itself — hundreds of megabytes of it — so it is copied rather than
/// read into memory, its name has to match what is actually on disk, and the
/// option must not be offered for the many meetings whose audio was deleted the
/// moment they finalized.
@Suite("Meeting audio export")
struct AudioExportTests {
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A fraction of a second of silence. No test here may touch a real
    /// recording or write anything a person would notice.
    @discardableResult
    private func writeTake(named name: String, frames: AVAudioFrameCount, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        let writer = try IncrementalCAFWriter(url: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        _ = try writer.append(buffer)
        writer.finish()
        return url
    }

    /// Each capture retry allocates its own take, so a meeting directory can
    /// hold several. The one worth exporting is the one holding the audio.
    @Test("The longest take is the one offered")
    func longestTakeIsExported() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeTake(named: "system-0.caf", frames: 4_800, in: directory)
        try writeTake(named: "system-1.caf", frames: 24_000, in: directory)
        try writeTake(named: "system-2.caf", frames: 9_600, in: directory)

        #expect(MeetingAudioExport.source(in: directory)?.lastPathComponent == "system-1.caf")
    }

    /// Meetings recorded before takes existed wrote one `system.caf`.
    @Test("A pre-takes recording is still exportable")
    func legacyFilenameIsFound() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeTake(named: "system.caf", frames: 4_800, in: directory)

        #expect(MeetingAudioExport.source(in: directory)?.lastPathComponent == "system.caf")
    }

    @Test("A directory with nothing in it offers nothing")
    func missingAudioResolvesToNothing() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(MeetingAudioExport.source(in: directory) == nil)
        #expect(MeetingAudioExport.source(in: directory.appending(path: "never-existed")) == nil)
    }

    /// Audio is deleted as soon as a meeting finalizes unless it was asked to
    /// be kept, so for most meetings there is nothing to export and the menu
    /// item must say so before it is pressed rather than after.
    @Test("Only a meeting that kept its audio offers it")
    func availabilityFollowsRetention() {
        #expect(MeetingAudioExport.isAvailable(retainsAudio: true, status: .ready))
        #expect(MeetingAudioExport.isAvailable(retainsAudio: false, status: .ready) == false)
    }

    /// Deletion happens after a successful finalization. A meeting that never
    /// got there still has its recording on disk, and that recording is the
    /// only copy of the meeting — it is exactly the one worth handing over.
    @Test("An interrupted meeting still has its recording")
    func interruptedMeetingsKeepAudioUntilFinalized() {
        #expect(MeetingAudioExport.isAvailable(retainsAudio: false, status: .interrupted))
        #expect(MeetingAudioExport.isAvailable(retainsAudio: false, status: .failed))
        #expect(MeetingAudioExport.isAvailable(retainsAudio: false, status: .idle) == false)
    }

    /// A disabled item with no explanation is a dead end. The menu keeps the
    /// option in place for every meeting -- so the feature is discoverable at
    /// all -- and the item itself says why it cannot be pressed.
    @Test("An unavailable audio export explains itself in the menu")
    func menuTitleExplainsWhyItIsDisabled() {
        #expect(MeetingAudioExport.menuTitle(isAvailable: true) == "Audio (.caf)")

        let unavailable = MeetingAudioExport.menuTitle(isAvailable: false)
        #expect(unavailable != MeetingAudioExport.menuTitle(isAvailable: true))
        #expect(unavailable.lowercased().contains("audio"))
        #expect(unavailable.lowercased().contains("not kept"))
    }

    /// The extension has to be the one on disk. A `.caf` named `.m4a` is a file
    /// no player will open.
    @Test("The suggested name follows the title and the file's own extension")
    func filenameMatchesDisk() {
        let source = URL(filePath: "/tmp/meeting/system-1.caf")

        #expect(MeetingAudioExport.filename(title: "Roadmap review", source: source) == "Roadmap review.caf")
        #expect(MeetingAudioExport.filename(title: " Q3 / Planning ", source: source) == "Q3 - Planning.caf")
        #expect(MeetingAudioExport.filename(title: "x", source: source).hasSuffix("." + source.pathExtension))
    }

    /// A recording is too big to read into `Data` and write back out, so it is
    /// copied. `copyItem` refuses a destination that exists, and by this point
    /// the save panel has already asked the user about replacing it.
    @Test("The recording is copied, over an existing file if the user chose one")
    func copyReplacesTheDestination() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeTake(named: "system-0.caf", frames: 4_800, in: directory)
        let destination = directory.appending(path: "Roadmap review.caf")
        try Data("older export".utf8).write(to: destination)

        try MeetingExporter.copyAudio(from: source, to: destination)

        #expect(try Data(contentsOf: destination) == (try Data(contentsOf: source)))
        #expect(try AVAudioFile(forReading: destination).length == 4_800)
        // The original stays where the app keeps it; an export is a copy.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Copying a recording that is no longer there fails loudly")
    func copyOfMissingSourceThrows() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try MeetingExporter.copyAudio(
                from: directory.appending(path: "system-0.caf"),
                to: directory.appending(path: "copy.caf")
            )
        }
    }
}
