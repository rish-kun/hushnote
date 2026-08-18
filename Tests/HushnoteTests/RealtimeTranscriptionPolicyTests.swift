import Foundation
import Testing
@testable import Hushnote

/// Running a live pass costs a second Whisper model on the same Neural Engine
/// the final pass will use, and puts a small model's guesses on screen while
/// the meeting is happening. Some people want neither. Turning it off has to
/// change more than one thing, though: a progress bar that reports "Stopping
/// live transcription…" for work that never started is a lie, and the live
/// transcript is also the safety net under a final pass that fails.
@Suite("Realtime transcription policy")
struct RealtimeTranscriptionPolicyTests {
    @Test("Nothing is announced when the live pass is running normally")
    func noNoticeWhenEnabled() {
        #expect(LiveTranscriptionPolicy.notice(isEnabled: true) == nil)
    }

    /// The recording screen's empty state says "Listening for the
    /// conversation…", which is not true when nothing is listening. The notice
    /// sits directly above it and says what will actually happen.
    @Test("A capture with no live pass says so, without implying work in flight")
    func noticeWhenDisabled() {
        let notice = LiveTranscriptionPolicy.notice(isEnabled: false)

        #expect(notice != nil)
        #expect(notice?.contains("off") == true)
        #expect(notice?.contains("Stop") == true)
        // Nothing is transcribing during capture, so nothing may say it is.
        #expect(notice?.lowercased().contains("transcribing") == false)
    }

    @Test("Finalization does not report a step that never happens")
    func stagesDropTheLivePassTeardown() {
        let withLive = LiveTranscriptionPolicy.stages(isEnabled: true)
        let withoutLive = LiveTranscriptionPolicy.stages(isEnabled: false)

        #expect(withLive.contains(.stoppingLiveTranscription))
        #expect(withoutLive.contains(.stoppingLiveTranscription) == false)
        #expect(withLive.first == .savingAudio)
        #expect(withoutLive.first == .savingAudio)
        #expect(withLive.last == .generatingInsights)
        #expect(withoutLive.last == .generatingInsights)
        #expect(withoutLive.count == withLive.count - 1)
    }

    /// The stage reached immediately after the audio file is closed.
    @Test("With no live pass, Stop goes straight to loading the final model")
    func stageAfterSavingAudio() {
        #expect(LiveTranscriptionPolicy.stageAfterSavingAudio(isEnabled: true) == .stoppingLiveTranscription)
        #expect(LiveTranscriptionPolicy.stageAfterSavingAudio(isEnabled: false) == .loadingFinalModel)
    }

    /// This branch already existed as a bare `guard` inside `stopMeeting`.
    /// Turning the live pass off makes it reachable on purpose rather than only
    /// when live transcription happened to fail, so it is worth a name.
    @Test("A failed final pass keeps a live transcript, and surfaces when there is none")
    func fallbackDependsOnWhatSurvived() {
        #expect(LiveTranscriptionPolicy.fallback(liveSegmentCount: 12) == .keepLiveTranscript)
        #expect(LiveTranscriptionPolicy.fallback(liveSegmentCount: 0) == .surfaceFailure)
    }
}

@Suite("Realtime transcription preference")
struct RealtimeTranscriptionDefaultsTests {
    private func scratchDefaults() -> UserDefaults {
        let suite = "dev.rishit.hushnote.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// On, because it is what the app does today. Turning it off for everyone
    /// who has not asked would change what happens during their next meeting
    /// without them touching anything.
    @MainActor
    @Test("A machine that has never been asked keeps the live pass")
    func defaultsToOn() {
        #expect(SpeechModelDefaults.liveTranscriptionEnabled(from: scratchDefaults()))
        #expect(AppViewState().liveTranscriptionEnabled)
    }

    @Test("The choice survives the launch that follows, in both directions")
    func choiceRoundTrips() {
        let defaults = scratchDefaults()

        SpeechModelDefaults.store(liveTranscriptionEnabled: false, in: defaults)
        #expect(SpeechModelDefaults.liveTranscriptionEnabled(from: defaults) == false)

        SpeechModelDefaults.store(liveTranscriptionEnabled: true, in: defaults)
        #expect(SpeechModelDefaults.liveTranscriptionEnabled(from: defaults))
    }

    /// `UserDefaults.bool(forKey:)` answers false for a key that was never
    /// written, which is the wrong answer here and the whole reason this is not
    /// a one-line read.
    @Test("An absent key is not the same as a stored false")
    func absentIsNotFalse() {
        let defaults = scratchDefaults()
        #expect(defaults.bool(forKey: SpeechModelDefaults.liveTranscriptionKey) == false)
        #expect(SpeechModelDefaults.liveTranscriptionEnabled(from: defaults))
    }
}
