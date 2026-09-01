@preconcurrency import AVFoundation
import Foundation

enum MeetingRecordingImportError: Error, Equatable, LocalizedError, Sendable {
    case sourceMissing
    case sourceIsNotAFile
    case unsupportedFileType(String)
    case noAudioTracks
    case destinationUnavailable(String)
    case trackConversionFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "The recording could not be found."
        case .sourceIsNotAFile:
            "Choose an audio or video file, not a folder."
        case .unsupportedFileType(let fileExtension):
            "The .\(fileExtension) file type is not supported. Choose CAF, M4A, MP3, WAV, MOV, MP4, or M4V."
        case .noAudioTracks:
            "This file does not contain a readable audio track."
        case .destinationUnavailable(let reason):
            "The imported recording could not be staged: \(reason)"
        case .trackConversionFailed(let ordinal, let reason):
            "Audio track \(ordinal + 1) could not be imported: \(reason)"
        }
    }
}

/// A Sendable identity for an audio track inside an AVFoundation-readable
/// container. AVAssetTrack itself deliberately never crosses the service seam.
struct ImportableRecordingTrack: Equatable, Sendable {
    /// Zero-based position in AVFoundation's audio-track list for this asset.
    /// It is intentionally scoped to this one import operation.
    let identifier: Int
    let label: String?
    let sourceStartMilliseconds: Int64

    init(identifier: Int, label: String? = nil, sourceStartMilliseconds: Int64 = 0) {
        self.identifier = identifier
        self.label = label
        self.sourceStartMilliseconds = max(0, sourceStartMilliseconds)
    }
}

struct NormalizedImportedTrack: Equatable, Sendable {
    let durationMilliseconds: Int64
    let sampleRate: Double
    let channelCount: Int

    init(durationMilliseconds: Int64, sampleRate: Double = 48_000, channelCount: Int = 1) {
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

protocol MeetingRecordingTrackExtracting: Sendable {
    func audioTracks(in sourceURL: URL) async throws -> [ImportableRecordingTrack]
    func normalize(
        track: ImportableRecordingTrack,
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NormalizedImportedTrack
}

/// The complete, not-yet-persisted graph produced by one import. Persistence
/// can save these values in one transaction and then enqueue finalization.
struct ImportedMeetingRecording: Equatable, Sendable {
    let session: RecordingSession
    let sources: [SessionAudioSource]
    let takes: [AudioTake]

    /// Compatibility bridge for the current decoder. Imported audio is never
    /// the local microphone, so it enters attribution as system-side speech.
    func finalizationTracks() -> [MeetingAudioTrack] {
        zip(sources, takes).map { _, take in
            MeetingAudioTrack(
                meetingID: session.meetingID,
                source: .system,
                fileURL: take.fileURL,
                sampleRate: take.sampleRate,
                channelCount: take.channelCount,
                timelineStartMilliseconds: take.timelineStartMilliseconds,
                durationMilliseconds: take.durationMilliseconds,
                isComplete: take.isComplete
            )
        }
    }
}

struct MeetingRecordingImportService: Sendable {
    typealias Progress = @Sendable (Double) -> Void

    static let supportedExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "m4a", "mp2", "mp3", "wav",
        "3g2", "3gp", "avi", "m4v", "mov", "mp4", "mpeg", "mpg"
    ]

    private let extractor: any MeetingRecordingTrackExtracting

    init(extractor: any MeetingRecordingTrackExtracting = AVFoundationMeetingRecordingTrackExtractor()) {
        self.extractor = extractor
    }

    func prepareImport(
        sourceURL: URL,
        destinationDirectory: URL,
        meetingID: UUID,
        sessionOrdinal: Int,
        timelineStartMilliseconds: Int64,
        importedAt: Date = Date(),
        progress: @escaping Progress = { _ in }
    ) async throws -> ImportedMeetingRecording {
        try Self.validate(sourceURL: sourceURL)
        try Task.checkCancellation()

        let tracks = try await extractor.audioTracks(in: sourceURL)
        guard !tracks.isEmpty else { throw MeetingRecordingImportError.noAudioTracks }

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            throw MeetingRecordingImportError.destinationUnavailable(error.localizedDescription)
        }

        let sessionID = UUID()
        let stageDirectory = destinationDirectory.appending(
            path: ".import-\(sessionID.uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try manager.createDirectory(at: stageDirectory, withIntermediateDirectories: false)
        } catch {
            throw MeetingRecordingImportError.destinationUnavailable(error.localizedDescription)
        }
        defer { try? manager.removeItem(at: stageDirectory) }

        progress(0)
        var normalizedTracks: [(ImportableRecordingTrack, NormalizedImportedTrack, URL)] = []
        normalizedTracks.reserveCapacity(tracks.count)

        for (ordinal, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let stagedURL = stageDirectory.appending(path: "imported-\(ordinal).caf")
            let base = Double(ordinal) / Double(tracks.count)
            let share = 1 / Double(tracks.count)
            let normalized: NormalizedImportedTrack
            do {
                normalized = try await extractor.normalize(
                    track: track,
                    from: sourceURL,
                    to: stagedURL,
                    progress: { value in progress(base + share * min(1, max(0, value))) }
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MeetingRecordingImportError.trackConversionFailed(ordinal, error.localizedDescription)
            }
            guard normalized.durationMilliseconds > 0 else {
                throw MeetingRecordingImportError.trackConversionFailed(ordinal, "the track contains no audio")
            }
            normalizedTracks.append((track, normalized, stagedURL))
        }

        var finalURLs: [URL] = []
        do {
            for (ordinal, item) in normalizedTracks.enumerated() {
                let finalURL = destinationDirectory.appending(
                    path: "imported-\(sessionID.uuidString)-\(ordinal).caf"
                )
                guard !manager.fileExists(atPath: finalURL.path) else {
                    throw MeetingRecordingImportError.destinationUnavailable(
                        "\(finalURL.lastPathComponent) already exists"
                    )
                }
                try manager.moveItem(at: item.2, to: finalURL)
                finalURLs.append(finalURL)
            }
        } catch {
            for url in finalURLs { try? manager.removeItem(at: url) }
            if let importError = error as? MeetingRecordingImportError { throw importError }
            throw MeetingRecordingImportError.destinationUnavailable(error.localizedDescription)
        }

        let timelineStart = max(0, timelineStartMilliseconds)
        let isMultitrack = normalizedTracks.count > 1
        var sources: [SessionAudioSource] = []
        var takes: [AudioTake] = []
        for (ordinal, item) in normalizedTracks.enumerated() {
            let source = SessionAudioSource(
                sessionID: sessionID,
                ordinal: ordinal,
                kind: isMultitrack ? .importedParticipant : .importedMix,
                label: item.0.label ?? (isMultitrack ? "Audio track \(ordinal + 1)" : "Imported audio"),
                isExpected: true
            )
            sources.append(source)
            takes.append(AudioTake(
                sourceID: source.id,
                ordinal: 0,
                fileURL: finalURLs[ordinal],
                timelineStartMilliseconds: timelineStart + item.0.sourceStartMilliseconds,
                sampleRate: item.1.sampleRate,
                channelCount: item.1.channelCount,
                durationMilliseconds: item.1.durationMilliseconds,
                isComplete: true
            ))
        }

        let capturedDuration = zip(normalizedTracks, takes).map { item, take in
            (take.timelineStartMilliseconds - timelineStart) + item.1.durationMilliseconds
        }.max() ?? 0
        let session = RecordingSession(
            id: sessionID,
            meetingID: meetingID,
            ordinal: max(0, sessionOrdinal),
            origin: .imported,
            wallStartedAt: importedAt,
            wallEndedAt: importedAt,
            timelineStartMilliseconds: timelineStart,
            capturedDurationMilliseconds: capturedDuration,
            state: .captured
        )
        progress(1)
        return ImportedMeetingRecording(session: session, sources: sources, takes: takes)
    }

    private static func validate(sourceURL: URL, manager: FileManager = .default) throws {
        guard sourceURL.isFileURL, manager.fileExists(atPath: sourceURL.path) else {
            throw MeetingRecordingImportError.sourceMissing
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MeetingRecordingImportError.sourceIsNotAFile
        }
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw MeetingRecordingImportError.unsupportedFileType(fileExtension.isEmpty ? "unknown" : fileExtension)
        }
    }
}

enum MeetingRecordingImportPolicy {
    nonisolated static func canImport(into status: MeetingStatus?, recordingIsBusy: Bool) -> Bool {
        guard !recordingIsBusy else { return false }
        guard let status else { return true }
        return status == .idle || status == .ready || status == .failed || status == .interrupted
    }

    nonisolated static func suggestedTitle(for sourceURL: URL) -> String {
        let name = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported meeting" : String(name.prefix(200))
    }
}

struct AVFoundationMeetingRecordingTrackExtractor: MeetingRecordingTrackExtracting {
    func audioTracks(in sourceURL: URL) async throws -> [ImportableRecordingTrack] {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var result: [ImportableRecordingTrack] = []
        result.reserveCapacity(tracks.count)
        for (identifier, track) in tracks.enumerated() {
            let timeRange = try await track.load(.timeRange)
            let start = timeRange.start.seconds
            result.append(ImportableRecordingTrack(
                identifier: identifier,
                sourceStartMilliseconds: start.isFinite ? Int64(max(0, start) * 1_000) : 0
            ))
        }
        return result
    }

    func normalize(
        track descriptor: ImportableRecordingTrack,
        from sourceURL: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NormalizedImportedTrack {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.indices.contains(descriptor.identifier) else {
            throw MeetingRecordingImportError.noAudioTracks
        }
        let selectedTrack = tracks[descriptor.identifier]

        let timeRange = try await selectedTrack.load(.timeRange)
        let durationSeconds = timeRange.duration.seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: selectedTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard reader.canAdd(output) else {
            throw MeetingRecordingImportError.trackConversionFailed(0, "AVFoundation rejected the audio track")
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .caf)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard writer.canAdd(input) else {
            throw MeetingRecordingImportError.trackConversionFailed(0, "AVFoundation could not create a CAF writer")
        }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? MeetingRecordingImportError.trackConversionFailed(
                0,
                "AVFoundation could not start conversion"
            )
        }
        // Keep any container-level leading offset in the take descriptor, not
        // as synthetic silence at the front of this source original.
        writer.startSession(atSourceTime: timeRange.start)

        var frameCount: Int64 = 0
        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard input.isReadyForMoreMediaData else {
                    try await Task.sleep(for: .milliseconds(4))
                    continue
                }
                guard let sample = output.copyNextSampleBuffer() else { break }
                frameCount += Int64(CMSampleBufferGetNumSamples(sample))
                guard input.append(sample) else {
                    reader.cancelReading()
                    throw writer.error ?? MeetingRecordingImportError.trackConversionFailed(
                        0,
                        "AVFoundation refused an audio sample"
                    )
                }
                if durationSeconds.isFinite, durationSeconds > 0 {
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds - timeRange.start.seconds
                    progress(min(1, max(0, timestamp / durationSeconds)))
                }
            }
            try Task.checkCancellation()
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? MeetingRecordingImportError.trackConversionFailed(0, "the reader stopped early")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MeetingRecordingImportError.trackConversionFailed(0, "the CAF writer stopped early")
        }

        progress(1)
        return NormalizedImportedTrack(
            durationMilliseconds: Int64((Double(frameCount) / 48_000 * 1_000).rounded())
        )
    }
}
