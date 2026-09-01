@preconcurrency import AVFoundation
import Foundation

/// Removes microphone transcript segments that are acoustically the same
/// signal already present on the system track.
///
/// Original files remain untouched. The filter reads only a short aligned
/// window around each microphone segment and treats uncertainty as speech that
/// must be preserved.
struct AudioLeakageTranscriptFilter: Sendable {
    private let detector: AudioLeakageDetector
    private let analysisRate: Double
    private let maximumSourceFrames: Int

    init(
        detector: AudioLeakageDetector = AudioLeakageDetector(),
        analysisRate: Double = 8_000,
        maximumSourceFrames: Int = 24_576
    ) {
        self.detector = detector
        self.analysisRate = analysisRate
        self.maximumSourceFrames = maximumSourceFrames
    }

    func removingLikelySystemLeakage(
        from segments: [TranscriptSegment],
        tracks: [MeetingAudioTrack]
    ) async -> [TranscriptSegment] {
        await Task.detached(priority: .utility) {
            Self.filter(
                segments: segments,
                tracks: tracks,
                detector: detector,
                analysisRate: analysisRate,
                maximumSourceFrames: maximumSourceFrames
            )
        }.value
    }

    private static func filter(
        segments: [TranscriptSegment],
        tracks: [MeetingAudioTrack],
        detector: AudioLeakageDetector,
        analysisRate: Double,
        maximumSourceFrames: Int
    ) -> [TranscriptSegment] {
        let systemTracks = tracks.filter { $0.source == .system }
        let microphoneTracks = tracks.filter { $0.source == .microphone }
        let systemSegments = segments.filter { $0.source == .system }
        guard !systemTracks.isEmpty, !microphoneTracks.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.source == .microphone,
                  systemSegments.contains(where: {
                      min($0.endMilliseconds, segment.endMilliseconds)
                          > max($0.startMilliseconds, segment.startMilliseconds)
                  }),
                  let microphone = bestTrack(for: segment, in: microphoneTracks),
                  let system = bestTrack(for: segment, in: systemTracks),
                  abs(microphone.sampleRate - system.sampleRate) < 1,
                  microphone.sampleRate >= analysisRate
            else { return true }

            let overlapStart = max(
                segment.startMilliseconds,
                microphone.timelineStartMilliseconds,
                system.timelineStartMilliseconds
            )
            let overlapEnd = min(
                segment.endMilliseconds,
                trackEnd(microphone),
                trackEnd(system)
            )
            guard overlapEnd > overlapStart else { return true }

            let sourceRate = microphone.sampleRate
            let availableFrames = Int(
                (Double(overlapEnd - overlapStart) * sourceRate / 1_000).rounded(.down)
            )
            guard availableFrames >= 32 else { return true }
            let frameCount = min(availableFrames, maximumSourceFrames)
            let center = overlapStart + (overlapEnd - overlapStart) / 2
            let halfWindowMilliseconds = Int64(
                (Double(frameCount) / sourceRate * 500).rounded(.down)
            )
            let windowStart = max(overlapStart, center - halfWindowMilliseconds)

            guard let systemSamples = try? samples(
                from: system,
                meetingStartMilliseconds: windowStart,
                frameCount: frameCount
            ), let microphoneSamples = try? samples(
                from: microphone,
                meetingStartMilliseconds: windowStart,
                frameCount: frameCount
            ) else { return true }

            let stride = max(1, Int((sourceRate / analysisRate).rounded()))
            let reference = Swift.stride(from: 0, to: systemSamples.count, by: stride)
                .map { systemSamples[$0] }
            let candidate = Swift.stride(from: 0, to: microphoneSamples.count, by: stride)
                .map { microphoneSamples[$0] }
            let result = detector.analyze(
                system: reference,
                microphone: candidate,
                sampleRate: sourceRate / Double(stride)
            )
            return !result.isLikelyLeakage
        }
    }

    private static func bestTrack(
        for segment: TranscriptSegment,
        in tracks: [MeetingAudioTrack]
    ) -> MeetingAudioTrack? {
        tracks.max { lhs, rhs in
            overlap(segment, lhs) < overlap(segment, rhs)
        }.flatMap { overlap(segment, $0) > 0 ? $0 : nil }
    }

    private static func overlap(
        _ segment: TranscriptSegment,
        _ track: MeetingAudioTrack
    ) -> Int64 {
        max(0, min(segment.endMilliseconds, trackEnd(track))
            - max(segment.startMilliseconds, track.timelineStartMilliseconds))
    }

    private static func trackEnd(_ track: MeetingAudioTrack) -> Int64 {
        track.timelineStartMilliseconds + track.durationMilliseconds
    }

    private static func samples(
        from track: MeetingAudioTrack,
        meetingStartMilliseconds: Int64,
        frameCount: Int
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: track.fileURL)
        let localMilliseconds = max(
            0,
            meetingStartMilliseconds - track.timelineStartMilliseconds
        )
        file.framePosition = AVAudioFramePosition(
            (Double(localMilliseconds) * file.processingFormat.sampleRate / 1_000).rounded()
        )
        let remainingFrames = file.length - file.framePosition
        guard remainingFrames >= 32 else { return [] }
        let capacity = AVAudioFrameCount(min(Int64(frameCount), remainingFrames))
        guard capacity >= 32,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: capacity
              ) else { return [] }
        try file.read(into: buffer, frameCount: capacity)
        guard let channel = buffer.floatChannelData?.pointee else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
