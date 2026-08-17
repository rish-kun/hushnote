import SwiftUI

/// Where a speech model stands right now.
///
/// `ready` means the model has been loaded successfully in this session. There
/// is no API on the speech engine for asking what is already on disk, so the
/// screen does not claim to know.
enum ModelAvailability: Equatable, Sendable {
    case notInstalled
    /// Carries how far the fetch has got, because a spinner and the word
    /// "Downloading…" is all this screen used to say for the length of a
    /// several-hundred-megabyte transfer.
    case downloading(ModelDownloadProgress)
    case ready
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var progress: ModelDownloadProgress? {
        if case .downloading(let progress) = self { return progress }
        return nil
    }
}

/// What a meeting will use a model for. Hushnote runs two passes -- a live one
/// during capture and an accuracy-first one afterwards -- and they need not be
/// the same model, so a row says which of the two jobs it holds.
enum ModelRole: Equatable, Sendable {
    case live
    case final
    case both

    var caption: String {
        switch self {
        case .live: "Used live during capture"
        case .final: "Used for the final pass"
        case .both: "Used live and for the final pass"
        }
    }
}

/// The pill on the right of a model's name.
enum ModelBadge: Hashable, Sendable {
    /// This model is one a meeting will actually use right now.
    case active
    case recommended
    /// Still served, but a newer artifact supersedes it.
    case legacy
    case englishOnly

    var title: String {
        switch self {
        case .active: "Active"
        case .recommended: "Recommended"
        case .legacy: "Legacy"
        case .englishOnly: "English only"
        }
    }
}

struct ModelRow: Identifiable {
    var model: SpeechModel
    var availability: ModelAvailability
    var role: ModelRole?
    var badges: [ModelBadge]

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
            $0.displayName.lowercased() == value
                || $0.id.lowercased() == value
                || $0.runtimeIdentifier.lowercased() == value
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
            let role: ModelRole? = switch (model.id == live, model.id == final) {
            case (true, true): .both
            case (true, false): .live
            case (false, true): .final
            case (false, false): nil
            }
            return ModelRow(
                model: model,
                availability: availability[model.id] ?? .notInstalled,
                role: role,
                badges: badges(model: model, role: role)
            )
        }
    }

    /// At most two, ordered by how much they change what the user would do: the
    /// model in use, then why they might pick a different one.
    nonisolated static func badges(model: SpeechModel, role: ModelRole?) -> [ModelBadge] {
        var badges: [ModelBadge] = []
        if role != nil { badges.append(.active) }
        // A row already carrying "Active" does not also need to be told it is
        // the recommendation: the user is using it.
        if role == nil, model.id == SpeechModelCatalog.recommended.id {
            badges.append(.recommended)
        }
        if SpeechModelCatalog.legacy.contains(model.id) { badges.append(.legacy) }
        if !model.isMultilingual { badges.append(.englishOnly) }
        return badges
    }

    /// The two lists the screen is drawn as. Catalog order is preserved inside
    /// each, so a model does not move within its section as its state changes.
    ///
    /// A download in flight belongs under "Available": it has not landed, and
    /// moving the row between two sections halfway through a transfer is how a
    /// progress bar ends up somewhere the user is not looking.
    nonisolated static func partition(
        _ rows: [ModelRow]
    ) -> (downloaded: [ModelRow], available: [ModelRow]) {
        (
            downloaded: rows.filter { $0.availability == .ready },
            available: rows.filter { $0.availability != .ready }
        )
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

    /// Deliberately not gated on the recording phase. A download started before
    /// Record is still saturating the link during the meeting, so stopping it
    /// is exactly the thing a busy machine needs to allow.
    nonisolated static func canCancel(_ availability: ModelAvailability) -> Bool {
        availability.isDownloading
    }

    nonisolated static func downloadLabel(_ availability: ModelAvailability) -> String {
        switch availability {
        case .notInstalled: "Download"
        case .downloading: "Cancel"
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

    // MARK: - Meters
    //
    // Ordinal, and only ordinal. Hushnote has no word-error-rate or real-time
    // factor measurements of its own and will not print numbers it cannot
    // source, so both meters are a rank of the catalog against itself, mapped
    // onto the five segments the bars are drawn with.

    /// Accuracy ranks by the tier the catalog already assigns, then by
    /// generation -- Large v2 is behind every Large v3 build regardless of file
    /// size -- and then by artifact size, because within one generation a
    /// larger file is a less lossy compression of the same weights.
    nonisolated static func accuracyMeter(_ model: SpeechModel) -> Int {
        quintile(of: model.id, in: accuracyRanking)
    }

    /// Speed ranks by artifact size, largest first, and then lifts the turbo
    /// and distilled builds one segment: those are the same or smaller weights
    /// behind a decoder built to run faster, which is the entire reason Argmax
    /// publishes them separately.
    nonisolated static func speedMeter(_ model: SpeechModel) -> Int {
        let base = quintile(of: model.id, in: speedRanking)
        return isFastDecoder(model) ? min(5, base + 1) : base
    }

    private nonisolated static func isFastDecoder(_ model: SpeechModel) -> Bool {
        let identifier = model.runtimeIdentifier
        return identifier.contains("turbo") || identifier.contains("distil")
    }

    private nonisolated static func tierRank(_ tier: SpeechModelTier) -> Int {
        switch tier {
        case .fast: 0
        case .balanced: 1
        case .accurate: 2
        }
    }

    private nonisolated static let accuracyRanking: [String] = SpeechModelCatalog.all
        .sorted { lhs, rhs in
            let tiers = (tierRank(lhs.tier), tierRank(rhs.tier))
            if tiers.0 != tiers.1 { return tiers.0 < tiers.1 }
            let generations = (generation(lhs), generation(rhs))
            if generations.0 != generations.1 { return generations.0 < generations.1 }
            if lhs.approximateDownloadBytes != rhs.approximateDownloadBytes {
                return lhs.approximateDownloadBytes < rhs.approximateDownloadBytes
            }
            return lhs.id < rhs.id
        }
        .map(\.id)

    private nonisolated static let speedRanking: [String] = SpeechModelCatalog.all
        .sorted { lhs, rhs in
            if lhs.approximateDownloadBytes != rhs.approximateDownloadBytes {
                return lhs.approximateDownloadBytes > rhs.approximateDownloadBytes
            }
            return lhs.id < rhs.id
        }
        .map(\.id)

    private nonisolated static func generation(_ model: SpeechModel) -> Int {
        model.runtimeIdentifier.contains("large-v2") ? 0 : 1
    }

    private nonisolated static func quintile(of id: String, in ranking: [String]) -> Int {
        guard let index = ranking.firstIndex(of: id), !ranking.isEmpty else { return 1 }
        return min(5, 1 + (index * 5) / ranking.count)
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

/// The small segmented bar Handy uses to compare models at a glance. Five
/// segments, filled to an ordinal rank -- see `ModelListPolicy`'s meters for
/// why it is a rank and not a number.
struct ModelMeter: View {
    let title: String
    let filled: Int
    let tint: Color

    private let segments = 5

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2.5) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < filled ? tint : HushnoteTheme.rule.opacity(0.55))
                        .frame(width: 11, height: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(filled) out of \(segments)")
    }
}

struct ModelBadgePill: View {
    let badge: ModelBadge

    var body: some View {
        Text(badge.title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(foreground)
            .background(
                Capsule(style: .continuous).fill(background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(HushnoteTheme.rule.opacity(badge == .active ? 0 : 0.8), lineWidth: 0.8)
            )
    }

    private var foreground: Color {
        badge == .active ? HushnoteTheme.paperRaised : HushnoteTheme.secondaryInk
    }

    private var background: Color {
        badge == .active ? HushnoteTheme.vermilion : .clear
    }
}

/// The bar, the percentage and the transfer rate, which is the whole reason
/// this row is not a spinner.
struct ModelDownloadBar: View {
    let progress: ModelDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(HushnoteTheme.rule.opacity(0.5))
                    Capsule(style: .continuous)
                        .fill(HushnoteTheme.vermilion)
                        .frame(width: geometry.size.width * min(max(progress.fraction, 0), 1))
                }
            }
            .frame(height: 4)

            HStack {
                Text(ModelDownloadText.percentage(progress.fraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ModelDownloadText.rate(progress.bytesPerSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ModelDownloadText.percentage(progress.fraction))
    }
}

struct ModelManagerView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        let split = ModelListPolicy.partition(
            ModelListPolicy.rows(
                availability: coordinator.modelAvailability,
                draft: state.draft
            )
        )
        let isBusy = state.recordingPhase.isBusy

        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Speech models")
                        .font(HushnoteTheme.Font.pageTitle)
                    Text("Models are verified before they are loaded and never substituted silently. Setting a default downloads it if it is not here yet, and uses it once it lands.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 620, alignment: .leading)
                }

                if isBusy {
                    Label(
                        "Downloads pause while a meeting is being captured or finalized. They use the same Neural Engine as the transcriber. A download already running can still be cancelled.",
                        systemImage: "pause.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if !split.downloaded.isEmpty {
                    section("DOWNLOADED", rows: split.downloaded, isBusy: isBusy)
                }
                if !split.available.isEmpty {
                    section("AVAILABLE TO DOWNLOAD", rows: split.available, isBusy: isBusy)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Performance guidance", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.headline)
                    Text("Large v3 Turbo is tuned for live work on the supported M4 baseline. The accuracy and speed meters rank the catalog against itself; they are not measured word error rates. Hushnote never changes your selection silently.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                .padding(.top, 10)
            }
            .pageChrome()
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [ModelRow], isBusy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1.3)
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                modelRow(row, isBusy: isBusy)
                Divider().opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func modelRow(_ row: ModelRow, isBusy: Bool) -> some View {
        let isActive = row.role != nil

        HStack(alignment: .top, spacing: 22) {
            Image(systemName: isActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 25))
                .foregroundStyle(isActive ? AnyShapeStyle(HushnoteTheme.vermilionInk) : AnyShapeStyle(.secondary))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(row.model.displayName).font(.headline)
                    ForEach(row.badges, id: \.self) { ModelBadgePill(badge: $0) }
                }

                if let role = row.role {
                    Text(role.caption)
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.moss)
                }

                HStack(spacing: 10) {
                    Text(ModelListPolicy.sizeText(row.model))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    ModelMeter(
                        title: "Accuracy",
                        filled: ModelListPolicy.accuracyMeter(row.model),
                        tint: HushnoteTheme.moss
                    )
                    ModelMeter(
                        title: "Speed",
                        filled: ModelListPolicy.speedMeter(row.model),
                        tint: HushnoteTheme.vermilionInk
                    )
                }

                if let progress = row.availability.progress {
                    ModelDownloadBar(progress: progress)
                        .padding(.top, 3)
                }

                if case .failed(let reason) = row.availability {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.vermilionInk)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                Button(ModelListPolicy.downloadLabel(row.availability)) {
                    if ModelListPolicy.canCancel(row.availability) {
                        coordinator.cancelDownload(row.model)
                    } else {
                        Task { await coordinator.downloadModel(row.model) }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    !ModelListPolicy.canCancel(row.availability)
                        && !ModelListPolicy.canDownload(
                            availability: row.availability,
                            phase: state.recordingPhase
                        )
                )

                if row.role != .both {
                    Button("Set as default") {
                        Task { await coordinator.setDefaultModel(row.model) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isBusy)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(row))
    }

    private func accessibilityLabel(_ row: ModelRow) -> String {
        var parts = [row.model.displayName]
        parts.append(contentsOf: row.badges.map(\.title))
        if let progress = row.availability.progress {
            parts.append(ModelDownloadText.percentage(progress.fraction))
        } else {
            parts.append(ModelListPolicy.downloadLabel(row.availability))
        }
        return parts.joined(separator: ", ")
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
