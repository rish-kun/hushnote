import SwiftUI

/// Where a speech model stands right now.
///
/// `ready` means the model has been loaded successfully in this session. There
/// is no API on the speech engine for asking what is already on disk, so the
/// screen does not claim to know.
enum ModelAvailability: Equatable, Sendable {
    case notInstalled
    case downloading
    case ready
    case failed(String)
}

struct ModelRow: Identifiable {
    var model: SpeechModel
    var availability: ModelAvailability
    var role: String?

    var id: String { model.id }
}

/// Resolves the names the app carries around -- draft selections and display
/// names -- to catalog models.
///
/// The old rule was a chain of lowercased `contains` that fell through to Large
/// v3 for anything it did not recognise, so asking for Tiny downloaded a
/// three-gigabyte model.
enum SpeechModelResolver {
    nonisolated static func model(named name: String) -> SpeechModel {
        let value = name.lowercased()
        if let exact = SpeechModelCatalog.all.first(where: {
            $0.displayName.lowercased() == value || $0.id.lowercased() == value
        }) {
            return exact
        }
        return switch value {
        case let v where v.contains("turbo"): SpeechModelCatalog.whisperLargeV3Turbo
        case let v where v.contains("large-v3"): SpeechModelCatalog.whisperLargeV3
        case let v where v.contains("medium"): SpeechModelCatalog.whisperMedium
        case let v where v.contains("small"): SpeechModelCatalog.whisperSmall
        case let v where v.contains("base"): SpeechModelCatalog.whisperBase
        case let v where v.contains("tiny"): SpeechModelCatalog.whisperTiny
        default: SpeechModelCatalog.whisperLargeV3
        }
    }
}

enum ModelListPolicy {
    nonisolated static func rows(
        availability: [String: ModelAvailability],
        draft: MeetingDraft
    ) -> [ModelRow] {
        let live = SpeechModelResolver.model(named: draft.liveModel).id
        let final = SpeechModelResolver.model(named: draft.finalModel).id
        return SpeechModelCatalog.all.map { model in
            ModelRow(
                model: model,
                availability: availability[model.id] ?? .notInstalled,
                role: model.id == live ? "Live default" : (model.id == final ? "Final default" : nil)
            )
        }
    }

    /// A download loads a multi-gigabyte Core ML model onto the same Neural
    /// Engine the live transcriber and the final pass are using, so it waits
    /// until the machine is not in the middle of a meeting.
    nonisolated static func canDownload(
        availability: ModelAvailability,
        phase: RecordingPhase
    ) -> Bool {
        guard !phase.isBusy else { return false }
        switch availability {
        case .notInstalled, .failed: return true
        case .downloading, .ready: return false
        }
    }

    nonisolated static func downloadLabel(_ availability: ModelAvailability) -> String {
        switch availability {
        case .notInstalled: "Download"
        case .downloading: "Downloading…"
        case .ready: "Ready"
        case .failed: "Retry"
        }
    }

    nonisolated static func sizeText(_ model: SpeechModel) -> String {
        let gigabytes = Double(model.approximateDownloadBytes) / 1_000_000_000
        return gigabytes >= 1
            ? String(format: "~%.1f GB", gigabytes)
            : "~\(model.approximateDownloadBytes / 1_000_000) MB"
    }
}

/// What the app knows about a provider credential, and what it may claim.
enum CredentialFieldState: Equatable {
    /// The Keychain has not been asked yet.
    case unknown
    case absent
    case stored
    case verifying
    case verified
    case failed(String)
}

enum CredentialField {
    nonisolated static func canSubmit(entry: String, state: CredentialFieldState) -> Bool {
        guard state != .verifying else { return false }
        return !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func statusText(_ state: CredentialFieldState) -> String {
        switch state {
        case .unknown: ""
        case .absent: "No key is stored for this provider."
        case .stored: "A key is stored in your Keychain."
        case .verifying: "Checking the key with the provider…"
        case .verified: "The key works and is saved in your Keychain."
        case .failed(let reason): reason
        }
    }

    /// A key that verified is in the Keychain; leaving the plaintext in a view
    /// for the rest of the session serves nothing. A key that failed is left
    /// alone so it can be corrected rather than retyped.
    nonisolated static func clearsEntry(after state: CredentialFieldState) -> Bool {
        state == .verified
    }
}

/// The key lives in local state and nowhere else until it is saved, so an
/// unrelated re-render cannot resync the field out from under the typing.
struct APIKeyField: View {
    let provider: InsightProviderChoice
    @Environment(AppCoordinator.self) private var coordinator
    @State private var entry = ""
    @State private var status = CredentialFieldState.unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SecureField("API key", text: $entry)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 480)
                .onSubmit(submit)

            HStack(spacing: 12) {
                Button(status == .verifying ? "Verifying…" : "Save and verify", action: submit)
                    .buttonStyle(.bordered)
                    .disabled(!CredentialField.canSubmit(entry: entry, state: status))
                if status == .verifying {
                    ProgressView().controlSize(.small)
                }
            }

            let text = CredentialField.statusText(status)
            if !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(HushnoteTheme.vermilionInk) : AnyShapeStyle(.secondary))
                    .accessibilityLabel(text)
            }
        }
        .task(id: provider) {
            entry = ""
            status = await coordinator.hasStoredCredential(for: provider) ? .stored : .absent
        }
    }

    private var isFailure: Bool {
        if case .failed = status { return true }
        return false
    }

    private func submit() {
        guard CredentialField.canSubmit(entry: entry, state: status) else { return }
        let key = entry
        status = .verifying
        Task {
            let result = await coordinator.saveAndVerifyAPIKey(key, provider: provider)
            status = result
            if CredentialField.clearsEntry(after: result) { entry = "" }
        }
    }
}

struct ModelManagerView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let rows = ModelListPolicy.rows(
            availability: coordinator.modelAvailability,
            draft: state.draft
        )
        let isBusy = state.recordingPhase.isBusy

        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Speech models")
                        .font(HushnoteTheme.Font.pageTitle)
                    Text("Models are verified before they are loaded and never substituted silently.")
                        .foregroundStyle(.secondary)
                }

                if isBusy {
                    Label(
                        "Downloads pause while a meeting is being captured or finalized. They use the same Neural Engine as the transcriber.",
                        systemImage: "pause.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                ForEach(rows) { row in
                    modelRow(row, isBusy: isBusy)
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
            .pageChrome()
        }
    }

    @ViewBuilder
    private func modelRow(_ row: ModelRow, isBusy: Bool) -> some View {
        let isDefault = row.role != nil

        HStack(alignment: .top, spacing: 22) {
            Image(systemName: isDefault ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 25))
                .foregroundStyle(isDefault ? AnyShapeStyle(HushnoteTheme.vermilionInk) : AnyShapeStyle(.secondary))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.model.displayName).font(.headline)
                    if let role = row.role {
                        Text(role.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.model.tier.rawValue.capitalized + (row.model.isMultilingual ? " · multilingual" : ""))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(ModelListPolicy.sizeText(row.model))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if case .failed(let reason) = row.availability {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(HushnoteTheme.vermilionInk)
                            .lineLimit(2)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if row.availability == .downloading {
                    ProgressView().controlSize(.small)
                }
                Button(ModelListPolicy.downloadLabel(row.availability)) {
                    Task { await coordinator.downloadModel(row.model) }
                }
                .buttonStyle(.bordered)
                .disabled(!ModelListPolicy.canDownload(
                    availability: row.availability,
                    phase: state.recordingPhase
                ))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.model.displayName), \(ModelListPolicy.downloadLabel(row.availability))"
        )
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
                    .font(HushnoteTheme.Font.pageTitle)

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
                        APIKeyField(provider: state.selectedProvider)
                    } else if state.selectedProvider == .chatGPT {
                        Button("Connect ChatGPT") { Task { await coordinator.connectChatGPT() } }
                            .buttonStyle(.borderedProminent)
                            .tint(HushnoteTheme.inkFill)
                        Text("Uses Codex App Server’s managed login and Codex rate limits. It does not expose ChatGPT history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let tool = state.selectedProvider.agentCLITool {
                        AgentCLIStatusView(tool: tool)
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
            .pageChrome()
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

/// Says whether a coding-agent CLI can actually be used before a meeting is
/// committed to it. "Not installed", "signed out" and "updated past the flags
/// Hushnote relies on" are all things worth knowing here rather than halfway
/// through a summary.
struct AgentCLIStatusView: View {
    let tool: AgentCLITool
    @Environment(AppCoordinator.self) private var coordinator
    @State private var problem: String?
    @State private var isChecking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Runs the \(tool.executableName) you are already signed into, with its tools switched off and nothing but an empty folder to read. No API key needed. The transcript is sent to that provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(tool.executableName)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.vermilionInk)
                    .accessibilityLabel(problem)
            } else {
                Text("\(tool.displayName) is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Check again") { check() }
                .buttonStyle(.bordered)
                .disabled(isChecking)
        }
        .task(id: tool) { check() }
    }

    private func check() {
        isChecking = true
        Task {
            problem = await coordinator.agentCLIUnavailability(tool)
            isChecking = false
        }
    }
}
