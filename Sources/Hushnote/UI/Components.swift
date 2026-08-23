import SwiftUI

/// The one wording for each recording state.
///
/// This row is drawn in four places -- the floating pill, the sidebar footer,
/// the workspace header and the menu bar -- and they used to disagree about
/// what to call the same state.
enum RecordingStatusText {
    /// The compact form, for a pill or a menu item.
    nonisolated static func label(for phase: RecordingPhase) -> String {
        switch phase {
        case .idle: ""
        case .preparing: "Arming audio…"
        case .recording: "Recording"
        case .paused: "Recording paused"
        case .finalizing: "Finalizing"
        case .failed: "Recording stopped"
        }
    }

    /// The roomy form, for a workspace header that has space to keep the
    /// promise the app is built on.
    nonisolated static func detail(for phase: RecordingPhase) -> String {
        switch phase {
        case .recording: "Recording locally to this Mac"
        case .paused: "Capture paused. Audio already recorded is safe."
        default: label(for: phase)
        }
    }
}

/// How full a level meter is. Shared, because the two meters disagreed about
/// their own thresholds and only one of them clamped.
enum LevelMeterModel {
    nonisolated static func activeBars(level: Double, count: Int) -> Int {
        Int((clamp(level) * Double(count)).rounded(.down))
    }

    nonisolated static func isBarActive(_ index: Int, level: Double, count: Int) -> Bool {
        index < activeBars(level: level, count: count)
    }

    nonisolated static func percentage(_ level: Double) -> Int {
        Int((clamp(level) * 100).rounded())
    }

    private nonisolated static func clamp(_ level: Double) -> Double {
        min(max(level, 0), 1)
    }
}

/// A compact, application-wide recording controller hosted in the floating panel.
/// The pill owns its phase visibility so its host only needs to supply the app
/// environment.
struct RecordingPill: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Group {
            switch state.recordingPhase {
            case .preparing:
                progressPill(title: RecordingStatusText.label(for: .preparing), accessibilityLabel: "Starting recording")
            case .recording, .paused:
                capturePill
            case .finalizing:
                progressPill(
                    title: state.finalizationLabel,
                    accessibilityLabel: "Finalizing transcript"
                )
            case .idle, .failed:
                EmptyView()
            }
        }
    }

    private var capturePill: some View {
        let isPaused = state.recordingPhase == .paused

        return HStack(spacing: 10) {
            RecordingPulse(isActive: !isPaused)

            Text(RecordingStatusText.label(for: state.recordingPhase))
                .font(.callout.weight(.semibold))
                .foregroundStyle(isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(HushnoteTheme.vermilionInk))

            Text(DurationText.clock(state.elapsed))
                .font(.callout.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
                .accessibilityLabel("Elapsed time \(DurationText.spoken(state.elapsed))")

            Divider()
                .frame(height: 22)

            MiniAudioLevel(
                level: state.systemLevel,
                systemImage: "speaker.wave.2.fill",
                label: "System audio",
                tint: HushnoteTheme.vermilion
            )

            Divider()
                .frame(height: 22)

            Button {
                Task { await coordinator.togglePause() }
            } label: {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")

            Button {
                Task { await coordinator.stopMeeting() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(HushnoteTheme.vermilion, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop and finalize")
            .accessibilityLabel("Stop recording and finalize transcript")
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        .recordingPillSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isPaused ? "Recording paused" : "Recording in progress")
    }

    private func progressPill(title: String, accessibilityLabel: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.callout.weight(.semibold))
        }
        .recordingPillSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct MiniAudioLevel: View {
    let level: Double
    let systemImage: String
    let label: String
    let tint: Color

    private let barCount = 4

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(isActive(index) ? tint : Color.secondary.opacity(0.16))
                        .frame(width: 2.5, height: CGFloat(5 + index * 2))
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue("\(LevelMeterModel.percentage(level)) percent")
    }

    private func isActive(_ index: Int) -> Bool {
        LevelMeterModel.isBarActive(index, level: level, count: barCount)
    }
}

private extension View {
    func recordingPillSurface() -> some View {
        padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
}

struct RecordingPulse: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            if isActive && !reduceMotion {
                Circle()
                    .fill(HushnoteTheme.vermilion.opacity(0.16))
                    .frame(width: 20, height: 20)
                    .scaleEffect(expanded ? 1.55 : 0.9)
                    .opacity(expanded ? 0 : 1)
            }
            Circle()
                .fill(isActive ? HushnoteTheme.vermilion : .secondary.opacity(0.45))
                .frame(width: 8, height: 8)
        }
        .frame(width: 24, height: 24)
        .task(id: isActive) {
            guard isActive, !reduceMotion else {
                expanded = false
                return
            }
            withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct LevelMeter: View {
    let level: Double
    let label: String
    let tint: Color

    private let bars = 9

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(LevelMeterModel.isBarActive(index, level: level, count: bars) ? tint : Color.secondary.opacity(0.15))
                        .frame(width: 3, height: CGFloat(5 + (index % 4) * 3))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) audio level")
        .accessibilityValue("\(LevelMeterModel.percentage(level)) percent")
    }
}

/// Reads `systemLevel` — written once per Core Audio buffer, tens of times a
/// second — inside a leaf so the observation dependency never reaches a parent
/// body that also renders the live transcript.
struct SystemLevelMeter: View {
    @Environment(AppViewState.self) private var state

    var body: some View {
        LevelMeter(level: state.systemLevel, label: "System", tint: HushnoteTheme.vermilion)
    }
}

/// Reads `elapsed`, which ticks every second, in isolation for the same reason.
struct ElapsedTimeLabel: View {
    var font: Font = .callout.monospacedDigit().weight(.medium)
    @Environment(AppViewState.self) private var state

    var body: some View {
        Text(DurationText.clock(state.elapsed))
            .font(font)
            .contentTransition(.numericText())
            .accessibilityLabel("Elapsed time \(DurationText.spoken(state.elapsed))")
    }
}

/// The post-Stop pipeline, shown above the meeting it is finalizing. Isolated
/// from its host so per-stage progress does not invalidate the workspace.
struct FinalizationBanner: View {
    @Environment(AppViewState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(state.finalizationLabel)
                .font(.callout.weight(.medium))
            Spacer()
            if case .finalizing(let progress) = state.recordingPhase {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 132)
                    .tint(HushnoteTheme.vermilion)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finalizing this meeting. \(state.finalizationLabel)")
    }
}

struct EmptyMeetingIllustration: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(HushnoteTheme.paperRaised)
                .stroke(HushnoteTheme.rule.opacity(0.7), lineWidth: 1)
                .frame(width: 178, height: 138)
                .rotationEffect(.degrees(2.5))

            VStack(alignment: .leading, spacing: 13) {
                Capsule().fill(HushnoteTheme.ink.opacity(0.78)).frame(width: 82, height: 5)
                Capsule().fill(HushnoteTheme.ink.opacity(0.18)).frame(width: 126, height: 3)
                Capsule().fill(HushnoteTheme.ink.opacity(0.18)).frame(width: 112, height: 3)
                HStack(spacing: 6) {
                    Circle().fill(HushnoteTheme.vermilion).frame(width: 7, height: 7)
                    Capsule().fill(HushnoteTheme.ink.opacity(0.34)).frame(width: 74, height: 3)
                }
                Capsule().fill(HushnoteTheme.ink.opacity(0.18)).frame(width: 120, height: 3)
            }
            .padding(22)
            .frame(width: 178, height: 138, alignment: .topLeading)
            .background(HushnoteTheme.paperRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(HushnoteTheme.rule.opacity(0.55)))
            .rotationEffect(.degrees(-3))
            .offset(x: -12, y: -4)
        }
        .frame(width: 206, height: 170)
        .accessibilityHidden(true)
    }
}

/// A moment in the meeting. It becomes a control only when there is somewhere
/// to go: with no action it is a label, not a keyboard stop that lies.
struct TimestampButton: View {
    let seconds: TimeInterval
    var action: (() -> Void)?

    init(seconds: TimeInterval, action: (() -> Void)? = nil) {
        self.seconds = seconds
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { stamp }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.accessibilityLabel(at: seconds, isInteractive: true))
        } else {
            stamp
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilityLabel(at: seconds, isInteractive: false))
        }
    }

    private var stamp: some View {
        Text(DurationText.clock(seconds))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(HushnoteTheme.moss)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(HushnoteTheme.moss.opacity(0.09), in: Capsule())
    }

    nonisolated static func accessibilityLabel(
        at seconds: TimeInterval,
        isInteractive: Bool
    ) -> String {
        let spoken = DurationText.spoken(seconds)
        return isInteractive ? "Jump to \(spoken)" : "At \(spoken)"
    }
}

/// One duration, two readings: the clock face on screen and the units a screen
/// reader speaks.
enum DurationText {
    /// `MM:SS` below an hour, `H:MM:SS` above it. Fractions truncate: a
    /// timestamp must point at the word that has already been said, never the
    /// one after it.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let (hours, minutes, secs) = components(seconds)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "1 hour 5 minutes 12 seconds", not "one hundred thirty five colon zero
    /// zero". Empty components are dropped rather than spoken as zeroes.
    nonisolated static func spoken(_ seconds: TimeInterval) -> String {
        let (hours, minutes, secs) = components(seconds)
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if secs > 0 || parts.isEmpty { parts.append(unit(secs, "second")) }
        return parts.joined(separator: " ")
    }

    private nonisolated static func components(
        _ seconds: TimeInterval
    ) -> (hours: Int, minutes: Int, seconds: Int) {
        let total = max(0, Int(seconds))
        return (total / 3_600, (total / 60) % 60, total % 60)
    }

    private nonisolated static func unit(_ value: Int, _ name: String) -> String {
        "\(value) \(name)\(value == 1 ? "" : "s")"
    }
}

struct ProviderDisclosure: View {
    let isLocal: Bool

    var body: some View {
        Label(
            isLocal ? "Transcript stays on this Mac" : "Transcript text will be sent to the selected provider",
            systemImage: isLocal ? "lock.laptopcomputer" : "network"
        )
        .font(.caption)
        .foregroundStyle(isLocal ? HushnoteTheme.moss : .secondary)
    }
}

// MARK: - Previews

/// Four values across the boundary that had no hours field. Seeing them side by
/// side is how `135:00` would have been caught on sight.
#Preview("Timestamps") {
    VStack(alignment: .leading, spacing: 14) {
        ForEach([0, 59, 3_912, 8_100] as [TimeInterval], id: \.self) { seconds in
            HStack(spacing: 16) {
                TimestampButton(seconds: seconds)
                TimestampButton(seconds: seconds) {}
                Text(DurationText.spoken(seconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(28)
}

#Preview("Level meters") {
    VStack(alignment: .leading, spacing: 18) {
        ForEach([0, 0.25, 0.5, 1.0, 1.6] as [Double], id: \.self) { level in
            HStack(spacing: 20) {
                LevelMeter(level: level, label: "System", tint: HushnoteTheme.vermilion)
                Text("\(LevelMeterModel.percentage(level))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(28)
}

#Preview("Recording states") {
    VStack(alignment: .leading, spacing: 16) {
        let phases: [RecordingPhase] = [
            .preparing, .recording, .paused, .finalizing(0.6), .failed("Capture stopped")
        ]
        ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
            HStack(spacing: 12) {
                RecordingPulse(isActive: phase == .recording)
                Text(RecordingStatusText.label(for: phase))
                    .font(.callout.weight(.semibold))
                Text(RecordingStatusText.detail(for: phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(28)
}

#Preview("Provider disclosure") {
    VStack(alignment: .leading, spacing: 14) {
        ProviderDisclosure(isLocal: true)
        ProviderDisclosure(isLocal: false)
    }
    .padding(28)
}

#Preview("Empty meeting") {
    EmptyMeetingIllustration()
        .padding(40)
        .paperBackground()
}
