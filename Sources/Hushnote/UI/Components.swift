import SwiftUI

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
                progressPill(title: "Starting recording…", accessibilityLabel: "Starting recording")
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

            Text(isPaused ? "Paused" : "Recording")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isPaused ? .secondary : HushnoteTheme.vermilion)

            Text(TimestampButton.format(state.elapsed))
                .font(.callout.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
                .accessibilityLabel("Elapsed time \(TimestampButton.format(state.elapsed))")

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
                    .frame(width: 18, height: 18)
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
                    .frame(width: 27, height: 27)
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
        .accessibilityValue("\(Int(clampedLevel * 100)) percent")
    }

    private var clampedLevel: Double {
        min(max(level, 0), 1)
    }

    private func isActive(_ index: Int) -> Bool {
        clampedLevel >= Double(index + 1) / Double(barCount)
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
                        .fill(Double(index) / Double(bars) < level ? tint : Color.secondary.opacity(0.15))
                        .frame(width: 3, height: CGFloat(5 + (index % 4) * 3))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) audio level")
        .accessibilityValue("\(Int(level * 100)) percent")
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

struct TimestampButton: View {
    let seconds: TimeInterval
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(Self.format(seconds))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(HushnoteTheme.moss)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(HushnoteTheme.moss.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to \(Self.format(seconds))")
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
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
