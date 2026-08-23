import Foundation
import Testing
@testable import Hushnote

@Suite("Application preferences")
struct AppPreferencesTests {
    private func scratch() -> (UserDefaults, AppPreferences) {
        let suite = "dev.rishit.hushnote.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, AppPreferences(defaults: defaults))
    }

    @Test("A new install keeps audio and uses the local provider")
    func defaults() {
        let (_, preferences) = scratch()
        #expect(preferences.retainAudio)
        #expect(preferences.selectedProvider == .local)
        #expect(preferences.modelStorageParentPath == nil)
    }

    @Test("Explicit settings survive a fresh preferences value")
    func roundTrip() {
        let (defaults, preferences) = scratch()
        preferences.retainAudio = false
        preferences.selectedProvider = .codexCLI
        preferences.localModelPath = "/models/quiet.gguf"
        preferences.llamaExecutablePath = "/usr/local/bin/llama-server"
        preferences.modelStorageParentPath = "/Volumes/Models/../Models"

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.retainAudio == false)
        #expect(restored.selectedProvider == .codexCLI)
        #expect(restored.localModelPath == "/models/quiet.gguf")
        #expect(restored.llamaExecutablePath == "/usr/local/bin/llama-server")
        #expect(restored.modelStorageParentPath == "/Volumes/Models")
        #expect(restored.modelStoragePaths.whisperDownloadBase?.path == "/Volumes/Models/Hushnote Models/WhisperKit")
    }

    @Test("Provider storage uses stable identifiers and rejects unknown values")
    func providerIDs() {
        let (defaults, preferences) = scratch()
        for provider in InsightProviderChoice.allCases {
            preferences.selectedProvider = provider
            #expect(AppPreferences(defaults: defaults).selectedProvider == provider)
            #expect(defaults.string(forKey: "insights.provider") == provider.stableID)
        }
        defaults.set("renamed-display-copy", forKey: "insights.provider")
        #expect(preferences.selectedProvider == .local)
    }

    @Test("Workspace destinations and per-meeting tabs round-trip and prune")
    func workspace() {
        let (defaults, preferences) = scratch()
        let kept = UUID()
        let removed = UUID()
        preferences.sidebarDestination = .meeting(kept)
        preferences.meetingTabs = [kept: .summary, removed: .ask]

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.sidebarDestination == .meeting(kept))
        #expect(restored.meetingTabs[kept] == .summary)
        #expect(restored.pruneMeetingTabs(keeping: [kept]) == [kept: .summary])
        #expect(restored.meetingTabs[removed] == nil)
    }
}
