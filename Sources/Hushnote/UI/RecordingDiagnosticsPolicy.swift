import Foundation

/// The lifecycle of one audio source as understood by the recording UI.
///
/// This is deliberately more specific than `AudioCaptureStatus`: system audio
/// and the microphone can be in different states while the meeting as a whole
/// continues. None of these values carries a colour. A view maps the semantic
/// tone returned below onto Hushnote's theme tokens.
enum RecordingSourceLifecycle: Equatable, Sendable {
    case disabled
    case arming
    case healthy
    case silent
    case reconnecting
    case degraded
    case unavailable
}

/// Evidence about one source, sampled slowly enough for presentation.
///
/// Levels do not belong here. A moving meter proves only that a buffer reached
/// memory; `durableWriterAdvanced` proves that the recovery file advanced.
struct RecordingSourceDiagnostics: Equatable, Sendable {
    let source: AudioSource
    let isExpected: Bool
    let isEnabled: Bool
    let lifecycle: RecordingSourceLifecycle
    let durableWriterAdvanced: Bool
    /// Seconds since this source last carried audible energy. `nil` means the
    /// source has not established an audible baseline yet.
    let lastAudibleAge: TimeInterval?
    let droppedBufferCount: Int

    init(
        source: AudioSource,
        isExpected: Bool = true,
        isEnabled: Bool = true,
        lifecycle: RecordingSourceLifecycle = .healthy,
        durableWriterAdvanced: Bool = true,
        lastAudibleAge: TimeInterval? = 0,
        droppedBufferCount: Int = 0
    ) {
        self.source = source
        self.isExpected = isExpected
        self.isEnabled = isEnabled
        self.lifecycle = lifecycle
        self.durableWriterAdvanced = durableWriterAdvanced
        self.lastAudibleAge = lastAudibleAge
        self.droppedBufferCount = max(0, droppedBufferCount)
    }

    var participatesInConfidence: Bool { isExpected && isEnabled }
}

enum RecordingLiveTextLifecycle: Equatable, Sendable {
    case disabled
    case arming
    case available
    case delayed
    case unavailable
}

enum RecordingDiskState: Equatable, Sendable {
    case healthy
    case low
    case critical
}

/// State shared by the independent source writers.
struct RecordingWriterDiagnostics: Equatable, Sendable {
    /// The normalized recovery-file rate, once known.
    let sampleRateHertz: Int?
    let diskState: RecordingDiskState

    init(sampleRateHertz: Int? = 48_000, diskState: RecordingDiskState = .healthy) {
        self.sampleRateHertz = sampleRateHertz
        self.diskState = diskState
    }
}

struct RecordingDiagnosticsSnapshot: Equatable, Sendable {
    let sources: [RecordingSourceDiagnostics]
    let liveText: RecordingLiveTextLifecycle
    let writer: RecordingWriterDiagnostics

    init(
        sources: [RecordingSourceDiagnostics],
        liveText: RecordingLiveTextLifecycle = .available,
        writer: RecordingWriterDiagnostics = .init()
    ) {
        self.sources = sources
        self.liveText = liveText
        self.writer = writer
    }

    func diagnostics(for source: AudioSource) -> RecordingSourceDiagnostics {
        sources.first(where: { $0.source == source })
            ?? RecordingSourceDiagnostics(
                source: source,
                isExpected: false,
                isEnabled: false,
                lifecycle: .disabled,
                durableWriterAdvanced: false,
                lastAudibleAge: nil
            )
    }
}

/// A styling intention, not a colour.
enum RecordingDiagnosticTone: Equatable, Sendable {
    case neutral
    case working
    case good
    case attention
    /// Reserved for an expected source that is unavailable.
    case warning
}

enum RecordingDiagnosticRowKind: Equatable, Sendable {
    case source(AudioSource)
    case liveText
    case writer
}

struct RecordingDiagnosticRow: Equatable, Sendable {
    let kind: RecordingDiagnosticRowKind
    let title: String
    let status: String
    let tone: RecordingDiagnosticTone
}

/// The four calm facts shown above the active meeting workspace.
enum RecordingDiagnosticsPolicy {
    static let expectedSampleRateHertz = 48_000

    nonisolated static func rows(
        for snapshot: RecordingDiagnosticsSnapshot
    ) -> [RecordingDiagnosticRow] {
        [
            sourceRow(snapshot.diagnostics(for: .system)),
            sourceRow(snapshot.diagnostics(for: .microphone)),
            liveTextRow(snapshot.liveText),
            writerRow(snapshot),
        ]
    }

    nonisolated static func sourceRow(
        _ diagnostics: RecordingSourceDiagnostics
    ) -> RecordingDiagnosticRow {
        let title = diagnostics.source == .system ? "System audio" : "Microphone"

        // An intentionally disabled source is not broken. This check comes
        // before lifecycle so stale `.unavailable` telemetry cannot turn a
        // microphone the user switched off into a warning.
        guard diagnostics.isEnabled else {
            return .init(kind: .source(diagnostics.source), title: title, status: "Off", tone: .neutral)
        }

        let status: String
        let baseTone: RecordingDiagnosticTone
        switch diagnostics.lifecycle {
        case .disabled:
            status = diagnostics.isExpected ? "Unavailable" : "Off"
            baseTone = diagnostics.isExpected ? .warning : .neutral
        case .arming:
            status = "Arming"
            baseTone = .working
        case .healthy:
            status = "Healthy"
            baseTone = .good
        case .silent:
            status = silenceStatus(age: diagnostics.lastAudibleAge)
            baseTone = prolongedSilence(diagnostics) ? .attention : .neutral
        case .reconnecting:
            status = "Reconnecting"
            baseTone = .working
        case .degraded:
            status = "Needs attention"
            baseTone = .attention
        case .unavailable:
            status = "Unavailable"
            baseTone = diagnostics.isExpected ? .warning : .neutral
        }

        if diagnostics.isExpected, diagnostics.droppedBufferCount > 0 {
            return .init(
                kind: .source(diagnostics.source),
                title: title,
                status: "Dropped audio",
                tone: .attention
            )
        }
        if diagnostics.isExpected,
           !diagnostics.durableWriterAdvanced,
           diagnostics.lifecycle != .arming,
           diagnostics.lifecycle != .reconnecting,
           diagnostics.lifecycle != .unavailable {
            return .init(
                kind: .source(diagnostics.source),
                title: title,
                status: "Not writing",
                tone: .attention
            )
        }
        return .init(kind: .source(diagnostics.source), title: title, status: status, tone: baseTone)
    }

    nonisolated static func liveTextRow(
        _ lifecycle: RecordingLiveTextLifecycle
    ) -> RecordingDiagnosticRow {
        let status: String
        let tone: RecordingDiagnosticTone
        switch lifecycle {
        case .disabled:
            status = "Off"
            tone = .neutral
        case .arming:
            status = "Starting"
            tone = .working
        case .available:
            status = "Available"
            tone = .good
        case .delayed:
            status = "Delayed"
            tone = .attention
        case .unavailable:
            status = "Unavailable"
            tone = .attention
        }
        return .init(kind: .liveText, title: "Live text", status: status, tone: tone)
    }

    nonisolated static func writerRow(
        _ snapshot: RecordingDiagnosticsSnapshot
    ) -> RecordingDiagnosticRow {
        let active = activeSources(in: snapshot)
        if snapshot.writer.diskState != .healthy {
            return .init(
                kind: .writer,
                title: "Writing audio",
                status: snapshot.writer.diskState == .critical ? "Disk critical" : "Low disk",
                tone: .attention
            )
        }
        if active.isEmpty {
            return .init(kind: .writer, title: "Writing audio", status: "Idle", tone: .neutral)
        }
        if active.allSatisfy({ $0.lifecycle == .arming }) {
            return .init(kind: .writer, title: "Writing audio", status: "Arming", tone: .working)
        }
        if active.contains(where: {
            !$0.durableWriterAdvanced
                && $0.lifecycle != .arming
                && $0.lifecycle != .reconnecting
        }) {
            return .init(
                kind: .writer,
                title: "Writing audio",
                status: "Not advancing",
                tone: .attention
            )
        }
        guard let sampleRate = snapshot.writer.sampleRateHertz else {
            return .init(
                kind: .writer,
                title: "Writing audio",
                status: "Format pending",
                tone: .working
            )
        }
        return .init(
            kind: .writer,
            title: "Writing audio",
            status: sampleRateText(sampleRate),
            tone: sampleRate == expectedSampleRateHertz ? .good : .attention
        )
    }

    fileprivate nonisolated static func activeSources(
        in snapshot: RecordingDiagnosticsSnapshot
    ) -> [RecordingSourceDiagnostics] {
        snapshot.sources.filter(\.participatesInConfidence)
    }

    fileprivate nonisolated static func prolongedSilence(
        _ diagnostics: RecordingSourceDiagnostics,
        threshold: TimeInterval = RecordingConfidencePolicy.prolongedSilenceThreshold
    ) -> Bool {
        guard diagnostics.participatesInConfidence,
              let age = diagnostics.lastAudibleAge else { return false }
        return age >= threshold
    }

    fileprivate nonisolated static func sampleRateText(_ hertz: Int) -> String {
        if hertz.isMultiple(of: 1_000) {
            return "\(hertz / 1_000) kHz"
        }
        let kilohertz = Double(hertz) / 1_000
        return kilohertz.formatted(.number.precision(.fractionLength(1))) + " kHz"
    }

    private nonisolated static func silenceStatus(age: TimeInterval?) -> String {
        guard let age, age >= 60 else { return "Silent" }
        return "Silent \(wholeMinutes(age)) min"
    }

    fileprivate nonisolated static func wholeMinutes(_ seconds: TimeInterval) -> Int {
        max(1, Int(seconds / 60))
    }
}

enum RecordingConfidenceKind: Equatable, Sendable {
    case sourceUnavailable([AudioSource])
    case diskCritical
    case diskLow
    case writerNotAdvancing([AudioSource])
    case buffersDropped(Int)
    case unexpectedWriteFormat(Int)
    case sourceDegraded(AudioSource)
    case liveTextDelayed
    case prolongedSilence(AudioSource, minutes: Int)
    case arming
    case reconnecting(AudioSource)
    case sourcesWritten([AudioSource])
    case noSourcesEnabled
}

struct RecordingConfidenceLine: Equatable, Sendable {
    let kind: RecordingConfidenceKind
    let text: String
    let tone: RecordingDiagnosticTone
}

/// Chooses one useful sentence rather than stacking every state the app knows.
///
/// The order is the product rule: an expected missing source first; then the
/// file itself (disk, writer advancement, drops and format); then delayed live
/// text while audio is safe; then prolonged silence; finally positive evidence
/// about the active source writers.
enum RecordingConfidencePolicy {
    static let prolongedSilenceThreshold: TimeInterval = 8 * 60

    nonisolated static func line(
        for snapshot: RecordingDiagnosticsSnapshot
    ) -> RecordingConfidenceLine {
        let active = RecordingDiagnosticsPolicy.activeSources(in: snapshot)
        let unavailable = snapshot.sources
            .filter { $0.isExpected && (!$0.isEnabled || $0.lifecycle == .disabled || $0.lifecycle == .unavailable) }
            .map(\.source)
            .sorted(by: sourceOrder)
        if !unavailable.isEmpty {
            return .init(
                kind: .sourceUnavailable(unavailable),
                text: unavailableText(unavailable),
                tone: .warning
            )
        }

        if snapshot.writer.diskState == .critical {
            return .init(
                kind: .diskCritical,
                text: "Disk space is critically low. Free space or remove finalized audio in Storage; audio already written is safe.",
                tone: .attention
            )
        }

        let stalled = active
            .filter {
                !$0.durableWriterAdvanced
                    && $0.lifecycle != .arming
                    && $0.lifecycle != .reconnecting
            }
            .map(\.source)
            .sorted(by: sourceOrder)
        if !stalled.isEmpty {
            return .init(
                kind: .writerNotAdvancing(stalled),
                text: writerNotAdvancingText(stalled),
                tone: .attention
            )
        }

        let drops = active.reduce(0) { $0 + $1.droppedBufferCount }
        if drops > 0 {
            return .init(
                kind: .buffersDropped(drops),
                text: drops == 1
                    ? "One audio buffer was dropped; recording continues."
                    : "\(drops) audio buffers were dropped; recording continues.",
                tone: .attention
            )
        }

        if let degraded = active.first(where: { $0.lifecycle == .degraded }) {
            return .init(
                kind: .sourceDegraded(degraded.source),
                text: "\(sourceName(degraded.source)) needs attention; recording continues.",
                tone: .attention
            )
        }

        if let sampleRate = snapshot.writer.sampleRateHertz,
           sampleRate != RecordingDiagnosticsPolicy.expectedSampleRateHertz {
            return .init(
                kind: .unexpectedWriteFormat(sampleRate),
                text: "Audio is writing at \(RecordingDiagnosticsPolicy.sampleRateText(sampleRate)); 48 kHz is expected.",
                tone: .attention
            )
        }

        if snapshot.writer.diskState == .low {
            return .init(
                kind: .diskLow,
                text: "Disk space is running low. Free space or remove finalized audio in Storage; recording continues.",
                tone: .attention
            )
        }

        if snapshot.liveText == .delayed || snapshot.liveText == .unavailable {
            return .init(
                kind: .liveTextDelayed,
                text: "Live transcription is delayed; recording is safe.",
                tone: .attention
            )
        }

        let silent = active
            .filter { RecordingDiagnosticsPolicy.prolongedSilence($0) }
            .sorted { lhs, rhs in
                (lhs.lastAudibleAge ?? 0) > (rhs.lastAudibleAge ?? 0)
            }
            .first
        if let silent, let age = silent.lastAudibleAge {
            let minutes = RecordingDiagnosticsPolicy.wholeMinutes(age)
            return .init(
                kind: .prolongedSilence(silent.source, minutes: minutes),
                text: "\(sourceName(silent.source)) has been silent for \(minutes) min.",
                tone: .attention
            )
        }

        if let arming = active.first(where: { $0.lifecycle == .arming }) {
            _ = arming
            return .init(kind: .arming, text: "Audio sources are arming.", tone: .working)
        }

        if let reconnecting = active.first(where: { $0.lifecycle == .reconnecting }) {
            return .init(
                kind: .reconnecting(reconnecting.source),
                text: "\(sourceName(reconnecting.source)) is reconnecting; audio already written is safe.",
                tone: .working
            )
        }

        if active.isEmpty {
            return .init(
                kind: .noSourcesEnabled,
                text: "No audio sources are enabled.",
                tone: .neutral
            )
        }

        let written = active.map(\.source).sorted(by: sourceOrder)
        return .init(
            kind: .sourcesWritten(written),
            text: writtenText(written),
            tone: .good
        )
    }

    private nonisolated static func sourceOrder(_ lhs: AudioSource, _ rhs: AudioSource) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private nonisolated static func rank(_ source: AudioSource) -> Int {
        source == .system ? 0 : 1
    }

    private nonisolated static func unavailableText(_ sources: [AudioSource]) -> String {
        switch sources {
        case [.system]: "System audio is unavailable."
        case [.microphone]: "Microphone is unavailable."
        default: "System audio and microphone are unavailable."
        }
    }

    private nonisolated static func writerNotAdvancingText(_ sources: [AudioSource]) -> String {
        switch sources {
        case [.system]: "System audio is not advancing on disk."
        case [.microphone]: "Microphone audio is not advancing on disk."
        default: "Audio is not advancing on disk."
        }
    }

    private nonisolated static func writtenText(_ sources: [AudioSource]) -> String {
        switch sources {
        case [.system]: "System audio is being written."
        case [.microphone]: "Microphone audio is being written."
        default: "Both sources are being written."
        }
    }

    private nonisolated static func sourceName(_ source: AudioSource) -> String {
        source == .system ? "System audio" : "Microphone"
    }
}
