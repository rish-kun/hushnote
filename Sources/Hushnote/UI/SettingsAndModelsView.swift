import SwiftUI

struct ModelManagerView: View {
    @Environment(AppCoordinator.self) private var coordinator

    private let models: [(name: String, role: String, size: String, note: String)] = [
        ("Whisper small", "Reduced resource", "~466 MB", "Fast multilingual transcription for quick checks."),
        ("Whisper medium", "Balanced", "~1.5 GB", "A practical middle ground for older Apple Silicon."),
        ("Whisper large-v3-turbo", "Live default", "~1.6 GB", "High-quality provisional text with lower decoder latency."),
        ("Whisper large-v3", "Final default", "~3 GB", "The accuracy-first post-meeting pass.")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Speech models")
                        .font(.system(size: 31, weight: .semibold, design: .serif))
                    Text("Models are verified before they are loaded and never substituted silently.")
                        .foregroundStyle(.secondary)
                }

                ForEach(models, id: \.name) { model in
                    HStack(alignment: .top, spacing: 22) {
                        Image(systemName: model.name.contains("large-v3") ? "waveform.circle.fill" : "waveform.circle")
                            .font(.system(size: 25))
                            .foregroundStyle(model.name.contains("large-v3") ? HushnoteTheme.vermilionInk : .secondary)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.name).font(.headline)
                                Text(model.role.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .tracking(0.8)
                                    .foregroundStyle(.secondary)
                            }
                            Text(model.note)
                                .foregroundStyle(.secondary)
                            Text(model.size)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Download") { Task { await coordinator.downloadModel(model.name) } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.5)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Performance guidance", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.headline)
                    Text("Large v3 Turbo is tuned for live work on the supported M4 baseline. Use Medium if sustained transcription falls behind; Hushnote never changes your selection silently.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: HushnoteTheme.contentMaxWidth, alignment: .leading)
            .padding(38)
        }
    }
}

struct SettingsView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Settings")
                    .font(.system(size: 31, weight: .semibold, design: .serif))

                settingsSection("PRIVACY") {
                    Toggle("Keep audio after finalization", isOn: $state.retainAudio)
                    Text("When off, temporary CAF tracks are removed after the final transcript and speaker pass succeed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsSection("INSIGHT PROVIDER") {
                    Picker("Provider", selection: $state.selectedProvider) {
                        ForEach(InsightProviderChoice.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    ProviderDisclosure(isLocal: state.selectedProvider.isLocal)

                    if state.selectedProvider == .openAI || state.selectedProvider == .anthropic {
                        SecureField("API key", text: Binding(
                            get: { "" },
                            set: { coordinator.stageAPIKey($0, provider: state.selectedProvider) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 480)
                        Button("Save and verify") { Task { await coordinator.saveStagedAPIKey(provider: state.selectedProvider) } }
                            .buttonStyle(.bordered)
                    } else if state.selectedProvider == .chatGPT {
                        Button("Connect ChatGPT") { Task { await coordinator.connectChatGPT() } }
                            .buttonStyle(.borderedProminent)
                            .tint(HushnoteTheme.inkFill)
                        Text("Uses Codex App Server’s managed login and Codex rate limits. It does not expose ChatGPT history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Path to llama-server executable", text: Binding(
                            get: { coordinator.localLlamaExecutablePath },
                            set: { coordinator.localLlamaExecutablePath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 540)
                        TextField("Path to GGUF model", text: Binding(
                            get: { coordinator.localModelPath },
                            set: { coordinator.localModelPath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 540)
                        Text("Hushnote launches the server on 127.0.0.1 only and stops it after the request.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsSection("RECORDING") {
                    Label("System Audio Recording Only", systemImage: "speaker.wave.2.fill")
                    Button("Open Privacy & Security") { coordinator.openPrivacySettings() }
                        .buttonStyle(.bordered)
                }

                settingsSection("LOCAL DATA") {
                    Text("Database and recoverable sessions")
                    Text(coordinator.applicationDataPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Reveal in Finder") { coordinator.revealApplicationData() }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: HushnoteTheme.contentMaxWidth, alignment: .leading)
            .padding(38)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1.3)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
