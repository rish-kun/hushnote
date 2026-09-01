import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Hushnote

@Suite("Meeting recording import")
struct MeetingRecordingImportTests {
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func writeGeneratedAudio(
        named name: String,
        frames: AVAudioFrameCount,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2,
        in directory: URL
    ) throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = sin(Float(frame) * 0.01) * 0.1
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test("AVFoundation normalizes generated audio into a 48 kHz mono CAF")
    func normalizesGeneratedAudio() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeGeneratedAudio(
            named: "source.wav",
            frames: 44_100,
            in: directory
        )
        let destination = directory.appending(path: "meeting", directoryHint: .isDirectory)
        let meetingID = UUID()

        let imported = try await MeetingRecordingImportService().prepareImport(
            sourceURL: source,
            destinationDirectory: destination,
            meetingID: meetingID,
            sessionOrdinal: 2,
            timelineStartMilliseconds: 12_000,
            importedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(imported.session.meetingID == meetingID)
        #expect(imported.session.origin == .imported)
        #expect(imported.session.ordinal == 2)
        #expect(imported.session.timelineStartMilliseconds == 12_000)
        #expect(imported.session.state == .captured)
        #expect(imported.sources.count == 1)
        #expect(imported.sources[0].kind == .importedMix)
        #expect(imported.takes.count == 1)
        #expect(imported.takes[0].isComplete)

        let file = try AVAudioFile(forReading: imported.takes[0].fileURL)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 1)
        #expect(abs(imported.takes[0].durationMilliseconds - 1_000) < 30)
        #expect(imported.session.capturedDurationMilliseconds == imported.takes[0].durationMilliseconds)

        let finalization = imported.finalizationTracks()
        #expect(finalization.count == 1)
        #expect(finalization[0].source == .system)
        #expect(finalization[0].timelineStartMilliseconds == 12_000)
    }

    @Test("Every exposed participant track becomes a separate original")
    func preservesMultipleTracks() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeGeneratedAudio(named: "source.caf", frames: 4_800, in: directory)
        let destination = directory.appending(path: "meeting", directoryHint: .isDirectory)
        let extractor = StubImportExtractor(tracks: [
            ImportableRecordingTrack(identifier: 7, label: "Alex", sourceStartMilliseconds: 0),
            ImportableRecordingTrack(identifier: 9, label: "Sam", sourceStartMilliseconds: 250)
        ], durations: [1_000, 700])

        let imported = try await MeetingRecordingImportService(extractor: extractor).prepareImport(
            sourceURL: source,
            destinationDirectory: destination,
            meetingID: UUID(),
            sessionOrdinal: 0,
            timelineStartMilliseconds: 4_000
        )

        #expect(imported.sources.map(\.kind) == [.importedParticipant, .importedParticipant])
        #expect(imported.sources.map(\.label) == ["Alex", "Sam"])
        #expect(imported.takes.map(\.sourceID) == imported.sources.map(\.id))
        #expect(imported.takes.map(\.timelineStartMilliseconds) == [4_000, 4_250])
        #expect(imported.takes.map(\.durationMilliseconds) == [1_000, 700])
        #expect(Set(imported.takes.map(\.fileURL)).count == 2)
        #expect(imported.takes.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        #expect(imported.session.capturedDurationMilliseconds == 1_000)
    }

    @Test("A conversion failure installs no partial originals")
    func failureIsTransactional() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeGeneratedAudio(named: "source.caf", frames: 4_800, in: directory)
        let destination = directory.appending(path: "meeting", directoryHint: .isDirectory)
        let extractor = StubImportExtractor(
            tracks: [ImportableRecordingTrack(identifier: 1), ImportableRecordingTrack(identifier: 2)],
            durations: [100],
            failingTrackID: 2
        )

        await #expect(throws: MeetingRecordingImportError.self) {
            try await MeetingRecordingImportService(extractor: extractor).prepareImport(
                sourceURL: source,
                destinationDirectory: destination,
                meetingID: UUID(),
                sessionOrdinal: 0,
                timelineStartMilliseconds: 0
            )
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        #expect(entries.isEmpty)
    }

    @Test("Validation rejects missing, folder, and unsupported inputs before discovery")
    func validatesInput() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "meeting", directoryHint: .isDirectory)
        let service = MeetingRecordingImportService(extractor: StubImportExtractor(tracks: [], durations: []))

        await #expect(throws: MeetingRecordingImportError.sourceMissing) {
            try await service.prepareImport(
                sourceURL: directory.appending(path: "missing.wav"),
                destinationDirectory: destination,
                meetingID: UUID(), sessionOrdinal: 0, timelineStartMilliseconds: 0
            )
        }
        await #expect(throws: MeetingRecordingImportError.sourceIsNotAFile) {
            try await service.prepareImport(
                sourceURL: directory,
                destinationDirectory: destination,
                meetingID: UUID(), sessionOrdinal: 0, timelineStartMilliseconds: 0
            )
        }
        let text = directory.appending(path: "notes.txt")
        try Data("not audio".utf8).write(to: text)
        await #expect(throws: MeetingRecordingImportError.unsupportedFileType("txt")) {
            try await service.prepareImport(
                sourceURL: text,
                destinationDirectory: destination,
                meetingID: UUID(), sessionOrdinal: 0, timelineStartMilliseconds: 0
            )
        }
    }

    @Test("A supported container without audio reports the actual problem")
    func rejectsNoAudio() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try writeGeneratedAudio(named: "source.caf", frames: 4_800, in: directory)

        await #expect(throws: MeetingRecordingImportError.noAudioTracks) {
            try await MeetingRecordingImportService(
                extractor: StubImportExtractor(tracks: [], durations: [])
            ).prepareImport(
                sourceURL: source,
                destinationDirectory: directory.appending(path: "meeting"),
                meetingID: UUID(),
                sessionOrdinal: 0,
                timelineStartMilliseconds: 0
            )
        }
    }

    @Test("Import availability is meeting-focused and titles follow the source")
    func importPolicy() {
        #expect(MeetingRecordingImportPolicy.canImport(into: nil, recordingIsBusy: false))
        #expect(MeetingRecordingImportPolicy.canImport(into: .ready, recordingIsBusy: false))
        #expect(MeetingRecordingImportPolicy.canImport(into: .interrupted, recordingIsBusy: false))
        #expect(!MeetingRecordingImportPolicy.canImport(into: .recording, recordingIsBusy: false))
        #expect(!MeetingRecordingImportPolicy.canImport(into: .ready, recordingIsBusy: true))
        #expect(MeetingRecordingImportPolicy.suggestedTitle(
            for: URL(filePath: "/tmp/ Roadmap follow-up .m4a")
        ) == "Roadmap follow-up")
    }

    @Test("Imported graph and queued job persist atomically")
    func persistsGraphAtomically() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Imported")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .imported,
            wallStartedAt: Date(),
            wallEndedAt: Date(),
            timelineStartMilliseconds: 0,
            capturedDurationMilliseconds: 1_000,
            state: .captured
        )
        let source = SessionAudioSource(
            sessionID: session.id,
            ordinal: 0,
            kind: .importedMix,
            label: "Imported audio"
        )
        let take = AudioTake(
            sourceID: source.id,
            ordinal: 0,
            fileURL: URL(filePath: "/tmp/imported.caf"),
            timelineStartMilliseconds: 0,
            sampleRate: 48_000,
            channelCount: 1,
            durationMilliseconds: 1_000,
            isComplete: true
        )
        let job = FinalizationJob(
            sessionID: session.id,
            modelID: "large-v3",
            audioDurationMilliseconds: 1_000
        )

        try await store.saveImportedRecording(
            session: session,
            sources: [source],
            takes: [take],
            job: job
        )
        let savedSession = try #require(try await store.recordingSession(id: session.id))
        #expect(savedSession.id == session.id)
        #expect(savedSession.origin == .imported)
        #expect(savedSession.capturedDurationMilliseconds == 1_000)
        #expect(try await store.sessionAudioSources(sessionID: session.id) == [source])
        #expect(try await store.audioTakes(sessionID: session.id) == [take])
        let savedJob = try #require(try await store.finalizationJob(id: job.id))
        #expect(savedJob.id == job.id)
        #expect(savedJob.sessionID == session.id)
        #expect(savedJob.state == .queued)

        let badSession = RecordingSession(
            meetingID: meeting.id,
            ordinal: 1,
            origin: .imported,
            wallStartedAt: Date(),
            wallEndedAt: Date(),
            timelineStartMilliseconds: 1_000,
            state: .captured
        )
        let mismatchedJob = FinalizationJob(
            sessionID: UUID(),
            modelID: "large-v3",
            audioDurationMilliseconds: 100
        )
        await #expect(throws: (any Error).self) {
            try await store.saveImportedRecording(
                session: badSession,
                sources: [],
                takes: [],
                job: mismatchedJob
            )
        }
        #expect(try await store.recordingSession(id: badSession.id) == nil)
    }
}

private struct StubImportFailure: Error {}

private struct StubImportExtractor: MeetingRecordingTrackExtracting {
    let tracks: [ImportableRecordingTrack]
    let durations: [Int64]
    var failingTrackID: Int?

    init(
        tracks: [ImportableRecordingTrack],
        durations: [Int64],
        failingTrackID: Int? = nil
    ) {
        self.tracks = tracks
        self.durations = durations
        self.failingTrackID = failingTrackID
    }

    func audioTracks(in sourceURL: URL) async throws -> [ImportableRecordingTrack] { tracks }

    func normalize(
        track: ImportableRecordingTrack,
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NormalizedImportedTrack {
        if track.identifier == failingTrackID { throw StubImportFailure() }
        guard let index = tracks.firstIndex(of: track), durations.indices.contains(index) else {
            throw StubImportFailure()
        }
        let writer = try IncrementalCAFWriter(url: destinationURL)
        let frames = AVAudioFrameCount(durations[index] * 48)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: IncrementalCAFWriter.recoveryFormat,
            frameCapacity: frames
        )!
        buffer.frameLength = frames
        _ = try writer.append(buffer)
        writer.finish()
        progress(1)
        return NormalizedImportedTrack(durationMilliseconds: durations[index])
    }
}
