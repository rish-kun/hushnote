import Foundation
import Testing
@testable import Hushnote

/// The recording status row was written four times -- in `Components`,
/// `AppShellView`, `MeetingWorkspaceView` and `HushnoteApp` -- and the four
/// disagreed: "Recording", "Recording paused", "Recording locally", "Capture
/// paused", "Paused". The state the design calls unmistakable was described
/// differently depending on where you looked at it.
@Suite("Shared chrome")
struct SharedChromeTests {
    @Test("One wording for each recording state")
    func statusWordingIsSingular() {
        #expect(RecordingStatusText.label(for: .preparing) == "Starting recording…")
        #expect(RecordingStatusText.label(for: .recording) == "Recording")
        #expect(RecordingStatusText.label(for: .paused) == "Recording paused")
        #expect(RecordingStatusText.label(for: .finalizing(0.4)) == "Finalizing")
        #expect(RecordingStatusText.label(for: .failed("stopped")) == "Recording stopped")
    }

    /// Idle has no status to state, and a label that said so would appear in
    /// the pill and the menu bar when nothing is happening.
    @Test("Idle says nothing")
    func idleHasNoLabel() {
        #expect(RecordingStatusText.label(for: .idle).isEmpty)
    }

    /// The roomy workspace header can say more than a pill can, but it says the
    /// same thing -- including where the audio is going, which is the whole
    /// promise of the app.
    @Test("The long form keeps the privacy claim")
    func detailKeepsThePrivacyClaim() {
        #expect(RecordingStatusText.detail(for: .recording) == "Recording locally to this Mac")
        #expect(RecordingStatusText.detail(for: .paused) == "Capture paused. Audio already recorded is safe.")
    }
}

/// The two level meters disagreed about their own thresholds: `MiniAudioLevel`
/// lit bar *i* at `(i+1)/count`, `LevelMeter` at `i/count` -- so `LevelMeter`
/// lit its first bar at any level above zero, showing signal during silence --
/// and only one of them clamped, so a level above 1 could report "150 percent"
/// to VoiceOver.
@Suite("Level meter")
struct LevelMeterModelTests {
    @Test("Silence lights nothing")
    func silenceIsEmpty() {
        #expect(LevelMeterModel.activeBars(level: 0, count: 9) == 0)
        #expect(LevelMeterModel.activeBars(level: 0.001, count: 9) == 0)
    }

    @Test("Full scale lights everything")
    func fullScaleIsFull() {
        #expect(LevelMeterModel.activeBars(level: 1, count: 9) == 9)
        #expect(LevelMeterModel.activeBars(level: 1, count: 4) == 4)
    }

    @Test("Out-of-range levels are clamped rather than drawn")
    func levelsAreClamped() {
        #expect(LevelMeterModel.activeBars(level: 1.5, count: 4) == 4)
        #expect(LevelMeterModel.activeBars(level: -0.5, count: 4) == 0)
        #expect(LevelMeterModel.percentage(1.5) == 100)
        #expect(LevelMeterModel.percentage(-0.5) == 0)
    }

    /// Both meters read the same signal, so at the same level they must agree
    /// about how full they are.
    @Test("The two meters agree at the same level")
    func metersAgreeProportionally() {
        #expect(LevelMeterModel.activeBars(level: 0.5, count: 4) == 2)
        #expect(LevelMeterModel.activeBars(level: 0.5, count: 8) == 4)
    }

    @Test("A bar is active only below the count that is lit")
    func barActivityFollowsTheCount() {
        #expect(LevelMeterModel.isBarActive(0, level: 0.25, count: 4))
        #expect(LevelMeterModel.isBarActive(1, level: 0.25, count: 4) == false)
    }
}
