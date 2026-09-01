@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
protocol MeetingAudioPlaying: AnyObject {
    func prepare(tracks: [MeetingAudioTrack]) async throws -> TimeInterval
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    func play(rate: Float)
    func pause()
    func seek(to seconds: TimeInterval)
    func stop()
}

@MainActor
final class AVFoundationMeetingAudioPlayer: MeetingAudioPlaying {
    private var player: AVPlayer?

    var currentTime: TimeInterval {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }
    var isPlaying: Bool { (player?.rate ?? 0) != 0 }

    func prepare(tracks: [MeetingAudioTrack]) async throws -> TimeInterval {
        stop()
        let composition = AVMutableComposition()
        var duration: TimeInterval = 0
        var insertedTrackCount = 0
        for descriptor in tracks where FileManager.default.fileExists(atPath: descriptor.fileURL.path) {
            let asset = AVURLAsset(url: descriptor.fileURL)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let destination = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let range = try await source.load(.timeRange)
            try destination.insertTimeRange(
                range,
                of: source,
                at: CMTime(seconds: Double(descriptor.timelineStartMilliseconds) / 1_000, preferredTimescale: 48_000)
            )
            insertedTrackCount += 1
            duration = max(
                duration,
                Double(descriptor.timelineStartMilliseconds + descriptor.durationMilliseconds) / 1_000
            )
        }
        guard insertedTrackCount > 0 else { throw MeetingPlaybackError.noRetainedAudio }
        player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        return duration
    }

    func play(rate: Float) {
        player?.playImmediately(atRate: rate)
    }

    func pause() { player?.pause() }

    func seek(to seconds: TimeInterval) {
        player?.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stop() {
        player?.pause()
        player = nil
    }
}

enum MeetingPlaybackError: Error, LocalizedError, Sendable {
    case noRetainedAudio
    var errorDescription: String? { "This meeting has no retained source audio to play." }
}

struct MeetingPlaybackJumpPoint: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case chapter, marker, speaker }
    let id: String
    let title: String
    let seconds: TimeInterval
    let kind: Kind
}

enum MeetingPlaybackPolicy {
    nonisolated static func activeSegmentID(
        at seconds: TimeInterval,
        transcript: [TranscriptLineItem]
    ) -> String? {
        transcript.first { seconds >= $0.start && seconds < max($0.start + 0.05, $0.end) }?.segmentID
    }

    nonisolated static func silenceSkipTarget(
        at seconds: TimeInterval,
        transcript: [TranscriptLineItem],
        minimumGap: TimeInterval = 8
    ) -> TimeInterval? {
        guard let next = transcript.first(where: { $0.start > seconds }),
              next.start - seconds >= minimumGap,
              !transcript.contains(where: { seconds >= $0.start && seconds < $0.end }) else { return nil }
        return next.start
    }

    nonisolated static func jumpPoints(
        transcript: [TranscriptLineItem],
        markers: [RecordingMarker]
    ) -> [MeetingPlaybackJumpPoint] {
        var points: [MeetingPlaybackJumpPoint] = []
        var chapter = -1
        var previousSpeaker: String?
        for line in transcript.sorted(by: { $0.start < $1.start }) {
            let nextChapter = Int(line.start / 300)
            if nextChapter > chapter {
                chapter = nextChapter
                points.append(.init(
                    id: "chapter-\(chapter)",
                    title: chapter == 0 ? "Opening" : "Chapter \(chapter + 1)",
                    seconds: line.start,
                    kind: .chapter
                ))
            }
            if line.speaker != previousSpeaker {
                points.append(.init(
                    id: "speaker-\(line.speaker)-\(line.segmentID)",
                    title: line.speaker,
                    seconds: line.start,
                    kind: .speaker
                ))
                previousSpeaker = line.speaker
            }
        }
        points += markers.map {
            .init(
                id: "marker-\($0.id.uuidString)",
                title: $0.type.title,
                seconds: Double($0.timelineMilliseconds) / 1_000,
                kind: .marker
            )
        }
        return points.sorted { ($0.seconds, $0.id) < ($1.seconds, $1.id) }
    }
}

@MainActor
@Observable
final class MeetingPlaybackController {
    private(set) var meetingID: UUID?
    private(set) var isAvailable = false
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var activeSegmentID: String?
    private(set) var jumpPoints: [MeetingPlaybackJumpPoint] = []
    var rate: Float = 1
    var skipsLongSilence = false

    @ObservationIgnored private let engine: any MeetingAudioPlaying
    @ObservationIgnored private var transcript: [TranscriptLineItem] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(engine: any MeetingAudioPlaying = AVFoundationMeetingAudioPlayer()) {
        self.engine = engine
    }

    func load(
        meetingID: UUID,
        tracks: [MeetingAudioTrack],
        transcript: [TranscriptLineItem],
        markers: [RecordingMarker]
    ) async throws {
        if self.meetingID == meetingID, isAvailable { return }
        ticker?.cancel()
        engine.stop()
        self.meetingID = meetingID
        self.transcript = transcript.sorted { $0.start < $1.start }
        jumpPoints = MeetingPlaybackPolicy.jumpPoints(transcript: transcript, markers: markers)
        duration = try await engine.prepare(tracks: tracks)
        position = 0
        activeSegmentID = nil
        isAvailable = true
        isPlaying = false
    }

    func togglePlayback() {
        guard isAvailable else { return }
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard isAvailable else { return }
        engine.play(rate: rate)
        isPlaying = true
        startTicker()
    }

    func pause() {
        engine.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        position = min(duration, max(0, engine.currentTime))
        activeSegmentID = MeetingPlaybackPolicy.activeSegmentID(at: position, transcript: transcript)
    }

    func seek(to seconds: TimeInterval) {
        let target = min(duration, max(0, seconds))
        engine.seek(to: target)
        position = target
        activeSegmentID = MeetingPlaybackPolicy.activeSegmentID(at: target, transcript: transcript)
    }

    func skip(seconds: TimeInterval) { seek(to: position + seconds) }

    func setRate(_ value: Float) {
        rate = min(2, max(0.5, value))
        if isPlaying { engine.play(rate: rate) }
    }

    func jump(to point: MeetingPlaybackJumpPoint) { seek(to: point.seconds) }

    func stop() {
        ticker?.cancel()
        ticker = nil
        engine.stop()
        meetingID = nil
        isAvailable = false
        isPlaying = false
        position = 0
        duration = 0
        activeSegmentID = nil
        jumpPoints = []
        transcript = []
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.refreshPosition()
            }
        }
    }

    private func refreshPosition() {
        position = min(duration, max(0, engine.currentTime))
        if skipsLongSilence,
           let target = MeetingPlaybackPolicy.silenceSkipTarget(at: position, transcript: transcript) {
            seek(to: target)
        }
        activeSegmentID = MeetingPlaybackPolicy.activeSegmentID(at: position, transcript: transcript)
        if position >= duration, duration > 0 { pause() }
    }
}
