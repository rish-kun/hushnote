@preconcurrency import AVFoundation
import Foundation

enum MeetingAudioFileFormat: String, CaseIterable, Sendable {
    case m4a
    case originalCAF = "caf"

    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .m4a: "Audio (.m4a)"
        case .originalCAF: "Original audio (.caf)"
        }
    }
}

enum MeetingAudioExportError: Error, Equatable, LocalizedError, Sendable {
    case sourceMissing
    case sourceHasNoAudio
    case conversionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "The meeting's recording is no longer on disk."
        case .sourceHasNoAudio: "The meeting's recording does not contain any audio."
        case .conversionUnavailable(let reason): "This recording could not be converted to M4A: \(reason)"
        }
    }
}

protocol MeetingAudioM4AConverting: Sendable {
    func convert(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

struct AVFoundationMeetingAudioM4AConverter: MeetingAudioM4AConverting {
    func convert(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MeetingAudioExportError.sourceHasNoAudio
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
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
        guard reader.canAdd(readerOutput) else {
            throw MeetingAudioExportError.conversionUnavailable("the CAF reader rejected its audio track")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 16
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw MeetingAudioExportError.conversionUnavailable("the M4A writer rejected lossless audio")
        }
        writer.add(writerInput)
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? MeetingAudioExportError.conversionUnavailable("the reader or writer would not start")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard writerInput.isReadyForMoreMediaData else {
                    try await Task.sleep(for: .milliseconds(4))
                    continue
                }
                guard let sample = readerOutput.copyNextSampleBuffer() else { break }
                guard writerInput.append(sample) else {
                    reader.cancelReading()
                    throw writer.error ?? MeetingAudioExportError.conversionUnavailable("the writer refused an audio sample")
                }
                if duration.isFinite, duration > 0 {
                    let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    progress(min(1, max(0, seconds / duration)))
                }
            }
            try Task.checkCancellation()
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        guard reader.status == .completed else {
            throw reader.error ?? MeetingAudioExportError.conversionUnavailable("the CAF reader stopped early")
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MeetingAudioExportError.conversionUnavailable("the M4A writer did not finish")
        }
    }
}

/// Copies or converts a recording without ever exposing a partial destination.
/// The temporary file is a sibling of the requested destination so the final
/// move/replace remains on one volume.
struct MeetingAudioExportService: Sendable {
    typealias Progress = @Sendable (Double) -> Void

    private let converter: any MeetingAudioM4AConverting

    init(converter: any MeetingAudioM4AConverting = AVFoundationMeetingAudioM4AConverter()) {
        self.converter = converter
    }

    func export(
        source: URL,
        destination: URL,
        format: MeetingAudioFileFormat,
        progress: @escaping Progress = { _ in }
    ) async throws {
        try Self.validate(source: source)
        try Task.checkCancellation()
        progress(0)

        let staged = Self.stagedURL(for: destination, format: format)
        defer { try? FileManager.default.removeItem(at: staged) }

        switch format {
        case .originalCAF:
            try await Self.copy(source: source, destination: staged) { copied in
                progress(0.05 + 0.9 * copied)
            }
        case .m4a:
            progress(0.05)
            try await converter.convert(source: source, destination: staged) { converted in
                progress(0.05 + 0.9 * min(1, max(0, converted)))
            }
        }

        try Task.checkCancellation()
        try Self.validate(source: staged)
        progress(0.98)
        try await Self.install(staged: staged, destination: destination)
        progress(1)
    }

    static func validate(source: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw MeetingAudioExportError.sourceMissing
        }
        guard let file = try? AVAudioFile(forReading: source), file.length > 0 else {
            throw MeetingAudioExportError.sourceHasNoAudio
        }
    }

    private static func stagedURL(for destination: URL, format: MeetingAudioFileFormat) -> URL {
        destination.deletingLastPathComponent().appending(
            path: ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(format.fileExtension)"
        )
    }

    private static func copy(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let byteCount = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }
            var copied = 0
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
                copied += data.count
                if byteCount > 0 { progress(min(1, Double(copied) / Double(byteCount))) }
            }
            try output.synchronize()
        }.value
    }

    private static func install(staged: URL, destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: destination)
            }
        }.value
    }
}

/// Finalization must use the value snapshotted onto the meeting at Start. A
/// preference changed during capture applies to the next meeting, not this one.
enum MeetingAudioRetentionPolicy {
    nonisolated static func shouldDeleteAfterFinalization(meetingRetainsAudio: Bool) -> Bool {
        !meetingRetainsAudio
    }
}
