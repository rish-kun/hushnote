import AppKit
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
                .foregroundStyle(isPaused ? HushnoteTheme.secondaryInk : HushnoteTheme.vermilionInk)

            Text(DurationText.clock(state.elapsed))
                .font(.callout.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
                .accessibilityLabel("Captured time \(DurationText.spoken(state.elapsed))")

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
                .foregroundStyle(HushnoteTheme.secondaryInk)

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(isActive(index) ? tint : HushnoteTheme.rule.opacity(0.55))
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
            .background(HushnoteTheme.controlSurface, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(HushnoteTheme.rule.opacity(0.72), lineWidth: 1)
            }
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
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .frame(width: 48, alignment: .leading)

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(LevelMeterModel.isBarActive(index, level: level, count: bars) ? tint : HushnoteTheme.rule.opacity(0.55))
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

/// Keeps microphone meter updates at the same leaf boundary as system audio.
struct MicrophoneLevelMeter: View {
    @Environment(AppViewState.self) private var state

    var body: some View {
        LevelMeter(level: state.microphoneLevel, label: "You", tint: HushnoteTheme.moss)
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
            .accessibilityLabel("Captured time \(DurationText.spoken(state.elapsed))")
    }
}

/// Keeps the one-second clocks at a leaf boundary and names the distinction
/// that matters after an intentional pause.
struct RecordingDurationComparison: View {
    @Environment(AppViewState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Text("Captured \(DurationText.clock(state.elapsed))")
            Text("Wall \(DurationText.clock(state.wallElapsed))")
                .foregroundStyle(HushnoteTheme.secondaryInk)
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Captured \(DurationText.spoken(state.elapsed)); wall time \(DurationText.spoken(state.wallElapsed))"
        )
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
        .background(HushnoteTheme.controlSurface)
        .hushnoteBottomRule(opacity: 0.65)
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
    /// A rounded length, for prose rather than for a readout.
    nonisolated static func approximateMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        return minutes <= 1 ? "under a minute" : "\(minutes) min"
    }

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

// MARK: - Editorial utility controls

/// A compact, semantic button treatment for product-owned surfaces. It leaves
/// SwiftUI's `Button` intact, preserving keyboard activation, focus rings, and
/// VoiceOver semantics while avoiding platform-blue tints in the app chrome.
enum HushnoteButtonKind {
    case primary
    case secondary
    case quiet
    case recording
    /// A destructive action. `Button(role: .destructive)` otherwise falls back
    /// to the platform treatment, which is how four delete actions ended up
    /// looking like stock AppKit.
    case destructive
}

struct HushnoteButtonStyle: ButtonStyle {
    let kind: HushnoteButtonKind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? 10 : 13)
            .padding(.vertical, 8)
            .background(background.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule(style: .continuous))
            .overlay {
                if kind == .secondary || kind == .destructive {
                    Capsule(style: .continuous)
                        .stroke(strokeColor, lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .primary, .recording: .white
        case .secondary, .quiet: HushnoteTheme.ink
        case .destructive: HushnoteTheme.vermilionInk
        }
    }

    private var strokeColor: Color {
        kind == .destructive
            ? HushnoteTheme.vermilionInk.opacity(0.5)
            : HushnoteTheme.rule.opacity(0.85)
    }

    private var background: Color {
        switch kind {
        case .primary: HushnoteTheme.inkFill
        case .secondary: HushnoteTheme.controlSurface
        case .quiet, .destructive: .clear
        case .recording: HushnoteTheme.vermilion
        }
    }
}

extension View {
    /// Deliberately on `View`, not `Button`: the narrower form could not be
    /// applied after `.disabled()`, nor to a `Menu`, nor to a stack of related
    /// buttons -- which is why so many call sites fell back to `.bordered`.
    func hushnoteButton(_ kind: HushnoteButtonKind = .primary) -> some View {
        buttonStyle(HushnoteButtonStyle(kind: kind))
    }
}

/// The field chrome's measurements.
///
/// `TextFieldStyle._body` is nonisolated, so it cannot route through a
/// `ViewModifier` under strict concurrency -- the configuration would have to
/// cross an actor boundary. The chrome is therefore applied in two places, and
/// these constants are what keep them identical.
enum HushnoteFieldMetrics {
    static let focusRingWidth: CGFloat = 2
    static let focusRingOpacity: Double = 0.55
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 11
    static let verticalPadding: CGFloat = 9
    static let borderOpacity: Double = 0.88

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// The field chrome as a modifier, for the controls a `TextFieldStyle` cannot
/// reach: `SecureField`, `TextEditor`, and `TextField(axis:)`. Those fell back
/// to `.roundedBorder` and read as system controls beside app-styled ones.
struct HushnoteFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .font(.callout)
            .padding(.horizontal, HushnoteFieldMetrics.horizontalPadding)
            .padding(.vertical, HushnoteFieldMetrics.verticalPadding)
            .background(HushnoteTheme.controlSurface, in: HushnoteFieldMetrics.shape)
            .overlay {
                HushnoteFieldMetrics.shape
                    .stroke(HushnoteTheme.rule.opacity(HushnoteFieldMetrics.borderOpacity), lineWidth: 1)
            }
    }
}

extension View {
    func hushnoteField() -> some View { modifier(HushnoteFieldChrome()) }

    /// The focus ring the app owns, in moss rather than platform blue.
    ///
    /// Suppressing the system ring without replacing it would leave a keyboard
    /// user with no idea where they are, so this is not optional decoration.
    func hushnoteFocusRing(_ isFocused: Bool) -> some View {
        modifier(HushnoteFocusRing(isFocused: isFocused))
    }
}

struct HushnoteFocusRing: ViewModifier {
    let isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            HushnoteFieldMetrics.shape
                .strokeBorder(
                    HushnoteTheme.moss.opacity(isFocused ? HushnoteFieldMetrics.focusRingOpacity : 0),
                    lineWidth: HushnoteFieldMetrics.focusRingWidth
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isFocused)
        }
    }
}

struct HushnoteFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        // Without `.plain` the field keeps its platform presentation: an
        // `NSTextField` bezel and the system blue focus ring, drawn *inside*
        // the border below. Focus indication is the call site's job -- a
        // `TextFieldStyle` is stateless and cannot know about focus.
        configuration
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.callout)
            .padding(.horizontal, HushnoteFieldMetrics.horizontalPadding)
            .padding(.vertical, HushnoteFieldMetrics.verticalPadding)
            .background(HushnoteTheme.controlSurface, in: HushnoteFieldMetrics.shape)
            .overlay {
                HushnoteFieldMetrics.shape
                    .stroke(HushnoteTheme.rule.opacity(HushnoteFieldMetrics.borderOpacity), lineWidth: 1)
            }
    }
}

struct HushnoteToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? HushnoteTheme.moss : HushnoteTheme.rule.opacity(0.8))
                    .frame(width: 42, height: 24)
                Circle()
                    .fill(HushnoteTheme.paperRaised)
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .animation(.easeOut(duration: 0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A lightweight segmented control for two to four mutually exclusive choices.
/// Each segment remains a real `Button`, making it reachable with keyboard and
/// assistive technology without depending on a platform control tint.
struct HushnoteSegmentedControl<Selection: Hashable, Label: View>: View {
    let options: [Selection]
    @Binding var selection: Selection
    let label: (Selection) -> Label

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    label(option)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selection == option ? HushnoteTheme.selectionSurface : .clear, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(HushnoteTheme.controlSurface, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(HushnoteTheme.rule.opacity(0.75), lineWidth: 1)
        }
    }
}

// MARK: - Rules

/// The app's one hairline.
///
/// `Divider()` renders the platform separator colour, which is a cooler grey
/// than `rule` and does not follow the palette. Five call sites were drawing
/// separators at four different opacities, half of them platform-coloured.
struct HushnoteRule: View {
    var opacity: Double = 0.62

    var body: some View {
        Rectangle()
            .fill(HushnoteTheme.rule.opacity(opacity))
            .frame(height: 1)
            .allowsHitTesting(false)
    }
}

extension View {
    func hushnoteBottomRule(opacity: Double = 0.62) -> some View {
        overlay(alignment: .bottom) { HushnoteRule(opacity: opacity) }
    }
}

// MARK: - Labels

/// A section label. The string is written in sentence case and uppercased by
/// `textCase`, because a literal `"CLEANUP INVENTORY"` cannot be translated.
struct HushnoteEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(HushnoteTheme.Font.eyebrow)
            .tracking(HushnoteTheme.eyebrowTracking)
            .textCase(.uppercase)
            .foregroundStyle(HushnoteTheme.secondaryInk)
    }
}

/// A small state marker. The three hand-written variants disagreed on font,
/// weight and whether there was a pill at all.
enum HushnoteBadgeTone {
    /// Filled vermilion. Reserved for the meeting being recorded right now.
    case active
    case neutral
    case positive
    case alert
}

struct HushnoteBadge: View {
    let title: String
    var tone: HushnoteBadgeTone = .neutral

    var body: some View {
        Text(title)
            .font(HushnoteTheme.Font.eyebrow)
            .tracking(HushnoteTheme.eyebrowTracking)
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(foreground)
            .background(Capsule(style: .continuous).fill(background))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(border, lineWidth: 0.8)
            }
    }

    private var foreground: Color {
        switch tone {
        case .active: HushnoteTheme.paperRaised
        case .neutral: HushnoteTheme.secondaryInk
        case .positive: HushnoteTheme.moss
        case .alert: HushnoteTheme.vermilionInk
        }
    }

    private var background: Color {
        tone == .active ? HushnoteTheme.vermilion : .clear
    }

    private var border: Color {
        switch tone {
        case .active: .clear
        case .neutral: HushnoteTheme.rule.opacity(0.8)
        case .positive: HushnoteTheme.moss.opacity(0.55)
        case .alert: HushnoteTheme.vermilionInk.opacity(0.55)
        }
    }
}

/// One line of machine state: a scan result, a verification outcome, a health
/// check. Three files said this in three fonts, one of them with a bare
/// `ProgressView` and no label alignment.
enum HushnoteStatusTone {
    case neutral
    case working
    case good
    case warning
}

struct HushnoteStatusLine: View {
    let text: String
    var tone: HushnoteStatusTone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            switch tone {
            case .working:
                ProgressView().controlSize(.small).scaleEffect(0.72)
            default:
                if let symbol {
                    Image(systemName: symbol).font(.caption)
                }
            }
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String? {
        if let systemImage { return systemImage }
        switch tone {
        case .good: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .neutral, .working: return nil
        }
    }

    private var foreground: Color {
        switch tone {
        case .good: HushnoteTheme.moss
        case .warning: HushnoteTheme.vermilionInk
        case .neutral, .working: HushnoteTheme.secondaryInk
        }
    }
}

/// A symbol standing in for an illustration in an empty state.
struct HushnoteGlyph: View {
    let systemName: String
    var tone: Color = HushnoteTheme.secondaryInk

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(tone)
            .accessibilityHidden(true)
    }
}

/// A headline figure. The one previous instance was 37pt semibold rounded --
/// the only rounded face in the app, and larger than any page title.
struct HushnoteMetric: View {
    let value: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(HushnoteTheme.Font.metric)
                .foregroundStyle(HushnoteTheme.ink)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }
        }
    }
}

// MARK: - Sections

struct HushnoteSectionAction {
    let title: String
    var systemImage: String?
    let perform: () -> Void

    init(title: String, systemImage: String? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}

/// An eyebrow, an optional trailing action, and content. Three files carried a
/// near-identical private copy of this at three different spacings.
struct HushnoteSection<Content: View>: View {
    let title: String
    var action: HushnoteSectionAction?
    var spacing: CGFloat = 13
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .firstTextBaseline) {
                HushnoteEyebrow(title)
                Spacer(minLength: 8)
                if let action {
                    Button(action: action.perform) {
                        if let symbol = action.systemImage {
                            Label(action.title, systemImage: symbol)
                                .labelStyle(.iconOnly)
                        } else {
                            Text(action.title)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .help(action.title)
                    .accessibilityLabel(action.title)
                }
            }
            content
        }
    }
}

// MARK: - Inventory

/// The date column shared by every meeting-bearing row. The three hand-rolled
/// versions used 66pt, 70pt and 70pt, so their titles did not line up.
struct HushnoteRowDate: View {
    let date: Date
    /// Deleted rows show the year instead of a time, because the retention
    /// window is what matters there.
    var showsTime = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(HushnoteTheme.ink)
            Text(
                showsTime
                    ? date.formatted(date: .omitted, time: .shortened)
                    : date.formatted(.dateTime.year())
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(HushnoteTheme.secondaryInk)
        }
        .frame(width: 70, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Title, a controlled excerpt, and a dot-joined metadata line.
struct HushnoteRowIdentity<Accessory: View>: View {
    let title: String
    var excerpt: String?
    var metadata: [String] = []
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(HushnoteTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                accessory
            }
            if let excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.callout)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension HushnoteRowIdentity where Accessory == EmptyView {
    init(title: String, excerpt: String? = nil, metadata: [String] = []) {
        self.init(title: title, excerpt: excerpt, metadata: metadata) { EmptyView() }
    }
}

/// How an inventory row arranges its leading column. Extracted so the compact
/// adaptation is a value a test can assert, rather than a branch buried in a
/// view body.
enum InventoryRowLayout: Equatable, Sendable {
    /// Leading column beside the content.
    case columns
    /// Leading column stacked above the content.
    case stacked

    nonisolated static func arrangement(for policy: AdaptiveLayoutPolicy) -> Self {
        policy == .compact ? .stacked : .columns
    }

    nonisolated static func verticalPadding(for policy: AdaptiveLayoutPolicy) -> CGFloat {
        policy == .compact ? 16 : 18
    }

    nonisolated static func columnSpacing(for policy: AdaptiveLayoutPolicy) -> CGFloat {
        policy == .compact ? 12 : 22
    }
}

/// One ruled inventory row: meetings, deleted meetings, search results, models,
/// storage entries. Seven different vertical cadences and four divider
/// treatments collapse into this.
///
/// The row owns its own bottom rule, so call sites stop interleaving
/// `Divider()` between elements of a `ForEach`.
struct HushnoteInventoryRow<Leading: View, Content: View, Trailing: View>: View {
    let policy: AdaptiveLayoutPolicy
    /// Non-nil makes the leading and content region one plain button. Trailing
    /// actions stay outside it, so a menu is not swallowed by the row's tap
    /// target.
    var open: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let open {
                Button(action: open) {
                    body(isInteractive: true)
                }
                .buttonStyle(.plain)
            } else {
                body(isInteractive: false)
            }

            trailing
        }
        .padding(.vertical, InventoryRowLayout.verticalPadding(for: policy))
        .frame(maxWidth: .infinity, alignment: .leading)
        .hushnoteBottomRule()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func body(isInteractive: Bool) -> some View {
        let spacing = InventoryRowLayout.columnSpacing(for: policy)

        Group {
            switch InventoryRowLayout.arrangement(for: policy) {
            case .columns:
                HStack(alignment: .top, spacing: spacing) {
                    leading
                    content
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 8) {
                    leading
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension HushnoteInventoryRow where Leading == EmptyView {
    init(
        policy: AdaptiveLayoutPolicy,
        open: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(policy: policy, open: open, leading: { EmptyView() }, content: content, trailing: trailing)
    }
}

extension HushnoteInventoryRow where Trailing == EmptyView {
    init(
        policy: AdaptiveLayoutPolicy,
        open: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content
    ) {
        self.init(policy: policy, open: open, leading: leading, content: content, trailing: { EmptyView() })
    }
}

extension HushnoteInventoryRow where Leading == EmptyView, Trailing == EmptyView {
    init(
        policy: AdaptiveLayoutPolicy,
        open: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            policy: policy,
            open: open,
            leading: { EmptyView() },
            content: content,
            trailing: { EmptyView() }
        )
    }
}

/// The selectable list row behind the sidebar, the provider inventory and
/// search results. Those three drew the same affordance at corner radius 6, 7
/// and 8, and disagreed about whether a trailing count sat inside the button.
///
/// The count and any menu belong in `trailing`, outside the button, so numbers
/// land on the same x in every section.
struct HushnoteSelectableRow<Label: View, Trailing: View>: View {
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let label: Label
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? HushnoteTheme.selectionSurface : .clear)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension HushnoteSelectableRow where Trailing == EmptyView {
    init(isSelected: Bool, select: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.init(isSelected: isSelected, select: select, label: label, trailing: { EmptyView() })
    }
}

// MARK: - Page structure

/// One page header for every route. There were four, with three subtitle
/// colours, two spacings, and one page carrying no subtitle at all.
struct HushnotePageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    let policy: AdaptiveLayoutPolicy
    @ViewBuilder let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                heading
                Spacer(minLength: 18)
                actions
            }
            VStack(alignment: .leading, spacing: 14) {
                heading
                actions
            }
        }
        .padding(.bottom, policy == .compact ? 24 : 26)
        .hushnoteBottomRule(opacity: 0.68)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(HushnoteTheme.Font.pageTitle)
                .foregroundStyle(HushnoteTheme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .frame(maxWidth: 640, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension HushnotePageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, policy: AdaptiveLayoutPolicy) {
        self.init(title: title, subtitle: subtitle, policy: policy) { EmptyView() }
    }
}

/// The app's empty state. `ContentUnavailableView` was used in three places and
/// is unmistakably a system control on a page that is otherwise not.
struct HushnoteEmptyState<Illustration: View, Action: View>: View {
    let title: String
    let message: String
    var policy: AdaptiveLayoutPolicy = .regular
    @ViewBuilder let illustration: Illustration
    @ViewBuilder let action: Action

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 44) {
                illustration
                copy
            }
            VStack(alignment: .leading, spacing: 28) {
                illustration
                copy
            }
        }
        .padding(.vertical, policy == .compact ? 46 : 68)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(HushnoteTheme.Font.emptyStateTitle)
                .foregroundStyle(HushnoteTheme.ink)
            Text(message)
                .font(.callout)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .lineSpacing(3)
                .frame(maxWidth: 390, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            action.padding(.top, 4)
        }
    }
}

extension HushnoteEmptyState where Action == EmptyView {
    init(
        title: String,
        message: String,
        policy: AdaptiveLayoutPolicy = .regular,
        @ViewBuilder illustration: () -> Illustration
    ) {
        self.init(
            title: title,
            message: message,
            policy: policy,
            illustration: illustration,
            action: { EmptyView() }
        )
    }
}

/// A path with Copy and Reveal. Two files carried the same block, one calling
/// it a card.
struct HushnotePathDisclosure: View {
    let path: String
    var label = "Location"
    @State private var isExpanded = false

    var body: some View {
        HushnoteDisclosure(label, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                .hushnoteButton(.quiet)
            }
        }
    }
}

/// A disclosure whose triangle does not read as Finder. The label takes the
/// eyebrow treatment so it sits in the same hierarchy as a section heading.
struct HushnoteDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    HushnoteEyebrow(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded { content }
        }
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
