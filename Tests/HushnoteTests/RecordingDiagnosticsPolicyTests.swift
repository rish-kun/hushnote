import Foundation
import Testing
@testable import Hushnote

@Suite("Recording diagnostics")
struct RecordingDiagnosticsPolicyTests {
    @Test("Healthy sources produce the four calm evidence rows")
    func healthyRows() throws {
        let rows = RecordingDiagnosticsPolicy.rows(for: Self.healthySnapshot)

        #expect(rows.count == 4)
        #expect(rows[0] == .init(kind: .source(.system), title: "System audio", status: "Healthy", tone: .good))
        #expect(rows[1] == .init(kind: .source(.microphone), title: "Microphone", status: "Healthy", tone: .good))
        #expect(rows[2] == .init(kind: .liveText, title: "Live text", status: "Available", tone: .good))
        #expect(rows[3] == .init(kind: .writer, title: "Writing audio", status: "48 kHz", tone: .good))
    }

    @Test("An intentionally disabled microphone is off, never warning")
    func disabledMicrophoneIsNeutral() throws {
        let snapshot = Self.snapshot(
            microphone: .init(
                source: .microphone,
                isExpected: false,
                isEnabled: false,
                lifecycle: .unavailable,
                durableWriterAdvanced: false,
                lastAudibleAge: 4_000,
                droppedBufferCount: 12
            )
        )

        let row = try #require(
            RecordingDiagnosticsPolicy.rows(for: snapshot)
                .first { $0.kind == .source(.microphone) }
        )
        #expect(row.status == "Off")
        #expect(row.tone == .neutral)
        #expect(RecordingConfidencePolicy.line(for: snapshot).text == "System audio is being written.")
    }

    @Test("Only an expected unavailable source receives warning tone")
    func unavailableExpectedSourceWarns() throws {
        let microphone = RecordingSourceDiagnostics(
            source: .microphone,
            lifecycle: .unavailable,
            durableWriterAdvanced: false
        )
        let snapshot = Self.snapshot(microphone: microphone)
        let row = try #require(
            RecordingDiagnosticsPolicy.rows(for: snapshot)
                .first { $0.kind == .source(.microphone) }
        )

        #expect(row.status == "Unavailable")
        #expect(row.tone == .warning)
        #expect(RecordingConfidencePolicy.line(for: snapshot).kind == .sourceUnavailable([.microphone]))
    }

    @Test("Durable writer evidence outranks a healthy lifecycle")
    func writerEvidenceWinsRow() throws {
        let system = RecordingSourceDiagnostics(
            source: .system,
            lifecycle: .healthy,
            durableWriterAdvanced: false
        )
        let snapshot = Self.snapshot(system: system)
        let rows = RecordingDiagnosticsPolicy.rows(for: snapshot)

        #expect(rows[0].status == "Not writing")
        #expect(rows[0].tone == .attention)
        #expect(rows[3].status == "Not advancing")
        #expect(
            RecordingConfidencePolicy.line(for: snapshot).kind
                == .writerNotAdvancing([.system])
        )
    }

    @Test("Drops are clamped, summed, and reported without calling capture lost")
    func droppedBuffers() {
        let snapshot = Self.snapshot(
            system: .init(source: .system, droppedBufferCount: 2),
            microphone: .init(source: .microphone, droppedBufferCount: 1)
        )
        let line = RecordingConfidencePolicy.line(for: snapshot)

        #expect(line.kind == .buffersDropped(3))
        #expect(line.text == "3 audio buffers were dropped; recording continues.")
        #expect(line.tone == .attention)
        #expect(RecordingSourceDiagnostics(source: .system, droppedBufferCount: -4).droppedBufferCount == 0)
    }

    @Test("Writing format reports 48 kHz and flags a changed format")
    func writingFormat() {
        let expected = RecordingDiagnosticsPolicy.rows(for: Self.healthySnapshot).last
        #expect(expected?.status == "48 kHz")

        let changed = Self.snapshot(
            writer: .init(sampleRateHertz: 44_100)
        )
        #expect(RecordingDiagnosticsPolicy.rows(for: changed).last?.status == "44.1 kHz")
        #expect(
            RecordingConfidencePolicy.line(for: changed).kind
                == .unexpectedWriteFormat(44_100)
        )
    }

    @Test("A low disk row remains calm but wins the confidence line")
    func lowDisk() {
        let snapshot = Self.snapshot(writer: .init(diskState: .low))
        let row = RecordingDiagnosticsPolicy.rows(for: snapshot).last
        let line = RecordingConfidencePolicy.line(for: snapshot)

        #expect(row?.status == "Low disk")
        #expect(row?.tone == .attention)
        #expect(line.kind == .diskLow)
        #expect(line.text.contains("recording continues"))
        #expect(line.text.contains("finalized audio in Storage"))
    }
}

@Suite("Recording confidence")
struct RecordingConfidencePolicyTests {
    @Test("Unavailable source outranks every other condition")
    func unavailableWins() {
        let snapshot = RecordingDiagnosticsPolicyTests.snapshot(
            microphone: .init(
                source: .microphone,
                lifecycle: .unavailable,
                durableWriterAdvanced: false,
                lastAudibleAge: 900,
                droppedBufferCount: 8
            ),
            liveText: .delayed,
            writer: .init(sampleRateHertz: 44_100, diskState: .critical)
        )

        #expect(RecordingConfidencePolicy.line(for: snapshot).kind == .sourceUnavailable([.microphone]))
    }

    @Test("File evidence outranks delayed live text and silence")
    func fileEvidenceWins() {
        let silentMic = RecordingSourceDiagnostics(
            source: .microphone,
            lifecycle: .silent,
            lastAudibleAge: 900,
            droppedBufferCount: 1
        )
        let snapshot = RecordingDiagnosticsPolicyTests.snapshot(
            microphone: silentMic,
            liveText: .delayed
        )

        #expect(RecordingConfidencePolicy.line(for: snapshot).kind == .buffersDropped(1))
    }

    @Test("Delayed live text says the recording is safe")
    func liveTextDelay() {
        let snapshot = RecordingDiagnosticsPolicyTests.snapshot(liveText: .delayed)
        let line = RecordingConfidencePolicy.line(for: snapshot)

        #expect(line.kind == .liveTextDelayed)
        #expect(line.text == "Live transcription is delayed; recording is safe.")
    }

    @Test("Live text delay outranks prolonged silence")
    func liveTextBeforeSilence() {
        let snapshot = RecordingDiagnosticsPolicyTests.snapshot(
            microphone: .init(
                source: .microphone,
                lifecycle: .silent,
                lastAudibleAge: 8 * 60
            ),
            liveText: .delayed
        )

        #expect(RecordingConfidencePolicy.line(for: snapshot).kind == .liveTextDelayed)
    }

    @Test("Silence appears only at the eight minute threshold")
    func prolongedSilenceThreshold() {
        let notYet = RecordingDiagnosticsPolicyTests.snapshot(
            microphone: .init(
                source: .microphone,
                lifecycle: .silent,
                lastAudibleAge: 8 * 60 - 1
            )
        )
        #expect(
            RecordingConfidencePolicy.line(for: notYet).kind
                == .sourcesWritten([.system, .microphone])
        )

        let threshold = RecordingDiagnosticsPolicyTests.snapshot(
            microphone: .init(
                source: .microphone,
                lifecycle: .silent,
                lastAudibleAge: 8 * 60
            )
        )
        let line = RecordingConfidencePolicy.line(for: threshold)
        #expect(line.kind == .prolongedSilence(.microphone, minutes: 8))
        #expect(line.text == "Microphone has been silent for 8 min.")
    }

    @Test("Healthy dual and single source captures report what reached disk")
    func writtenSources() {
        let both = RecordingConfidencePolicy.line(for: RecordingDiagnosticsPolicyTests.healthySnapshot)
        #expect(both.kind == .sourcesWritten([.system, .microphone]))
        #expect(both.text == "Both sources are being written.")

        let systemOnly = RecordingDiagnosticsPolicyTests.snapshot(
            microphone: .init(
                source: .microphone,
                isExpected: false,
                isEnabled: false,
                lifecycle: .disabled,
                durableWriterAdvanced: false,
                lastAudibleAge: nil
            )
        )
        #expect(RecordingConfidencePolicy.line(for: systemOnly).text == "System audio is being written.")
    }
}

private extension RecordingDiagnosticsPolicyTests {
    static var healthySnapshot: RecordingDiagnosticsSnapshot { snapshot() }

    static func snapshot(
        system: RecordingSourceDiagnostics = .init(source: .system),
        microphone: RecordingSourceDiagnostics = .init(source: .microphone),
        liveText: RecordingLiveTextLifecycle = .available,
        writer: RecordingWriterDiagnostics = .init()
    ) -> RecordingDiagnosticsSnapshot {
        .init(sources: [system, microphone], liveText: liveText, writer: writer)
    }
}
