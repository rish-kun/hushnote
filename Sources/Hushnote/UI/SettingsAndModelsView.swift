import AppKit
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
                .textFieldStyle(.plain)
                .hushnoteField()
                .frame(maxWidth: 480)
                .onSubmit(submit)

            HStack(spacing: 12) {
                Button(status == .verifying ? "Verifying…" : "Save and verify", action: submit)
                    .hushnoteButton(.secondary)
                    .disabled(!CredentialField.canSubmit(entry: entry, state: status))
                if status == .verifying {
                    ProgressView().controlSize(.small)
                }
            }

            let text = CredentialField.statusText(status)
            if !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(HushnoteTheme.vermilionInk) : AnyShapeStyle(HushnoteTheme.secondaryInk))
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

/// Which model the chosen CLI should run.
///
/// Two affordances, because the tools disagree about how knowable their models
/// are: a menu of what this one actually listed, and a field that takes
/// anything. The field is the real control -- `codex` names no models at all,
/// and a CLI that is missing, signed out or offline names none either -- so the
/// menu appears beside it only when there is something to open it onto.
///
/// Empty is a deliberate answer, not an unfinished one: it leaves `--model` off
/// the command line entirely, so the CLI runs whatever the user configured in
/// it rather than a model Hushnote picked for them.
struct AgentCLIModelField: View {
    let tool: AgentCLITool
    @Environment(AppCoordinator.self) private var coordinator
    @State private var entry = ""
    @State private var discovered: [String] = []
    @State private var isDiscovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                TextField("Model", text: $entry)
                    .textFieldStyle(HushnoteFieldStyle())
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Model for \(tool.executableName)")
                    .onChange(of: entry) { coordinator.setAgentCLIModel(entry, for: tool) }

                if AgentCLIModelMenu.showsMenu(discovered: discovered, stored: stored) {
                    Menu("Choose…") {
                        ForEach(options, id: \.self) { model in
                            Button(model) { entry = model }
                        }
                        Divider()
                        Button("\(tool.executableName)'s own default") { entry = "" }
                    }
                    .fixedSize()
                    .accessibilityLabel("Models \(tool.executableName) offers")
                } else if isDiscovering {
                    ProgressView().controlSize(.small)
                }
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(captionStyle)
                .frame(maxWidth: 620, alignment: .leading)
                .accessibilityLabel(caption)

            if let note = listingNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .frame(maxWidth: 620, alignment: .leading)
            }
        }
        .task(id: tool) {
            entry = coordinator.agentCLIModel(for: tool)
            discovered = []
            isDiscovering = true
            discovered = await coordinator.agentCLIModels(tool)
            isDiscovering = false
        }
    }

    private var resolution: AgentCLIModelName.Resolution { AgentCLIModelName.resolve(entry) }

    private var stored: String? { AgentCLIModelName.argument(entry) }

    private var options: [String] {
        AgentCLIModelMenu.options(discovered: discovered, stored: stored)
    }

    private var caption: String {
        AgentCLIModelMenu.caption(executableName: tool.executableName, resolution: resolution)
    }

    private var captionStyle: AnyShapeStyle {
        if case .rejected = resolution { return AnyShapeStyle(HushnoteTheme.vermilionInk) }
        return AnyShapeStyle(HushnoteTheme.secondaryInk)
    }

    /// Why there is no menu, when there is no menu. A tool that lists nothing
    /// and a tool that could not be asked are different situations, and neither
    /// should read as the control having failed to load.
    private var listingNote: String? {
        guard !isDiscovering, discovered.isEmpty else { return nil }
        guard tool.modelListing != nil else {
            return "\(tool.executableName) does not list the models it takes, so type the name you want."
        }
        return "\(tool.executableName) listed no models just now. Type the name you want."
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
                .foregroundStyle(HushnoteTheme.secondaryInk)
            HStack(spacing: 2.5) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < filled ? tint : HushnoteTheme.rule.opacity(0.55))
                        .frame(width: 11, height: 4)
                }
            }
            Text("\(filled)/\(segments)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(HushnoteTheme.secondaryInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(filled) out of \(segments)")
    }
}

struct ModelBadgePill: View {
    let badge: ModelBadge

    var body: some View {
        Text(badge.title)
            .font(HushnoteTheme.Font.eyebrow)
            .tracking(HushnoteTheme.eyebrowTracking)
            .textCase(.uppercase)
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
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                Spacer()
                Text(ModelDownloadText.rate(progress.bytesPerSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(HushnoteTheme.secondaryInk.opacity(0.72))
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
            AdaptivePageScaffold { policy in
                VStack(alignment: .leading, spacing: policy == .compact ? 24 : 30) {
                HushnotePageHeader(
                    title: "Speech models",
                    subtitle: "Compare the local speech inventory, then download or make one model the default. Hushnote never substitutes a model silently.",
                    policy: policy
                )

                modelStorageSummary

                if isBusy {
                    Label(
                        "Downloads pause while a meeting is being captured or finalized. They use the same Neural Engine as the transcriber. A download already running can still be cancelled.",
                        systemImage: "pause.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                }

                if !split.downloaded.isEmpty {
                    section("DOWNLOADED", rows: split.downloaded, isBusy: isBusy, policy: policy)
                }
                if !split.available.isEmpty {
                    section("AVAILABLE TO DOWNLOAD", rows: split.available, isBusy: isBusy, policy: policy)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Performance guidance", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.headline)
                    Text("Large v3 Turbo is tuned for live work on the supported M4 baseline. The accuracy and speed meters rank the catalog against itself; they are not measured word error rates. Hushnote never changes your selection silently.")
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                .padding(.top, 10)
            }
            }
            .padding(.vertical, 36)
        }
    }

    private var modelStorageSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HushnoteEyebrow("Model location")
                Text(coordinator.modelStorageDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Manage Storage") { coordinator.setSelection(.storage) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 12)
        .hushnoteBottomRule(opacity: 0.6)
    }

    @ViewBuilder
    private func section(
        _ title: String,
        rows: [ModelRow],
        isBusy: Bool,
        policy: AdaptiveLayoutPolicy
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HushnoteEyebrow(title)
            ForEach(rows) { row in
                modelRow(row, isBusy: isBusy, policy: policy)
                HushnoteRule(opacity: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func modelRow(_ row: ModelRow, isBusy: Bool, policy: AdaptiveLayoutPolicy) -> some View {
        let isActive = row.role != nil

        Group {
            if policy == .compact {
                VStack(alignment: .leading, spacing: 13) {
                    modelInformation(row, isActive: isActive, compact: true)
                    modelActions(row, isBusy: isBusy)
                }
            } else {
            HStack(alignment: .top, spacing: 22) {
                modelInformation(row, isActive: isActive, compact: false)
                Spacer(minLength: 18)
                modelActions(row, isBusy: isBusy)
            }
            }
        }
        .padding(.vertical, 6)
        // This row contains real buttons. Combining its descendants makes those
        // actions disappear into one VoiceOver element; contain keeps the useful
        // summary while leaving each control independently reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(row))
    }

    private func modelInformation(_ row: ModelRow, isActive: Bool, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: compact ? 12 : 18) {
            Image(systemName: isActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 25))
                .foregroundStyle(isActive ? AnyShapeStyle(HushnoteTheme.vermilionInk) : AnyShapeStyle(HushnoteTheme.secondaryInk))
                .frame(width: compact ? 28 : 34)

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

                if compact {
                    VStack(alignment: .leading, spacing: 5) {
                        modelFacts(row)
                    }
                } else {
                    modelFacts(row)
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
        }
    }

    private func modelFacts(_ row: ModelRow) -> some View {
        HStack(spacing: 10) {
            Text(coordinator.installedModelSizeText(row.model) ?? ModelListPolicy.sizeText(row.model))
                .font(.caption.monospacedDigit())
                .foregroundStyle(HushnoteTheme.secondaryInk.opacity(0.72))
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
    }

    private func modelActions(_ row: ModelRow, isBusy: Bool) -> some View {
        HStack(spacing: 10) {
            if row.availability != .ready {
            Button(ModelListPolicy.downloadLabel(row.availability)) {
                if ModelListPolicy.canCancel(row.availability) {
                    coordinator.cancelDownload(row.model)
                } else {
                    Task { await coordinator.downloadModel(row.model) }
                }
            }
            .hushnoteButton(.secondary)
            .disabled(
                !ModelListPolicy.canCancel(row.availability)
                    && !ModelListPolicy.canDownload(
                        availability: row.availability,
                        phase: state.recordingPhase
                    )
            )
            } else {
                Text("Downloaded")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HushnoteTheme.moss)
            }

            if row.role != .both {
                Button("Make default") {
                    Task { await coordinator.setDefaultModel(row.model) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(isBusy)
            }

            if row.availability == .ready, row.role == nil {
                Button("Remove") { coordinator.promptToRemoveModel(row.model) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.vermilionInk)
                    .disabled(isBusy || !coordinator.canChangeModelStorage)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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
            AdaptivePageScaffold { policy in
                VStack(alignment: .leading, spacing: policy == .compact ? 26 : 36) {
                    HushnotePageHeader(
                        title: "Settings",
                        subtitle: "Capture behaviour, retention, and which model writes your summaries.",
                        policy: policy
                    )

                    if policy == .wide {
                        HStack(alignment: .top, spacing: 44) {
                            behaviorSettings(state: state)
                            providerSettings(state: state, policy: policy)
                        }
                    } else {
                        behaviorSettings(state: state)
                        providerSettings(state: state, policy: policy)
                    }
                }
            }
            .padding(.vertical, 36)
        }
        .task { await coordinator.refreshMicrophoneDevices() }
    }

    private func behaviorSettings(state: AppViewState) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            settingsSection("APPEARANCE") {
                UtilitySettingRow(
                    title: "Appearance",
                    consequence: "Choose whether Hushnote follows macOS or uses a fixed light or dark appearance."
                ) {
                    AppearanceModeControl()
                }
            }

            settingsSection("CAPTURE") {
                UtilitySettingRow(
                    title: "Capture your microphone",
                    consequence: "Adds your voice as a separate source track and labels it You. You can turn it off or back on during a recording."
                ) {
                    Toggle("Capture your microphone", isOn: Binding(
                        get: { state.microphoneCaptureEnabled },
                        set: { coordinator.setMicrophoneCaptureEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(HushnoteToggleStyle())
                    .accessibilityLabel("Capture your microphone")
                }

                if state.microphoneCaptureEnabled {
                    UtilitySettingRow(
                        title: "Microphone input",
                        consequence: "Uses the system default until a specific microphone is selected. Hushnote remembers a chosen device by its hardware identifier."
                    ) {
                        MicrophoneInputControl(
                            selection: Binding(
                                get: { state.selectedMicrophone },
                                set: { coordinator.setSelectedMicrophone($0) }
                            ),
                            availableDevices: state.availableMicrophones
                        )
                    }
                }

                UtilitySettingRow(
                    title: "Live transcription",
                    consequence: "Loads a speech model during capture. Turn it off to write audio first and produce the final transcript after Stop."
                ) {
                    Toggle("Live transcription", isOn: Binding(
                        get: { state.liveTranscriptionEnabled },
                        set: { coordinator.setLiveTranscriptionEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(UtilitySwitchStyle())
                    .accessibilityLabel("Live transcription")
                }
            }

            settingsSection("RETENTION") {
                UtilitySettingRow(
                    title: "Keep audio after finalization",
                    consequence: "When off, temporary CAF tracks are removed after the transcript and speaker pass succeed."
                ) {
                    Toggle("Keep audio after finalization", isOn: Binding(
                        get: { state.retainAudio },
                        set: { coordinator.setRetainAudio($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(UtilitySwitchStyle())
                    .accessibilityLabel("Keep audio after finalization")
                }
            }

            settingsSection("RECORDING") {
                UtilitySettingRow(
                    title: "System audio recording",
                    consequence: "System audio is always captured as its own track. macOS permission is managed in Privacy & Security."
                ) {
                    Button("Open Privacy & Security") { coordinator.openPrivacySettings() }
                        .hushnoteButton(.secondary)
                }
            }

            settingsSection("LOCAL MANAGEMENT") {
                UtilitySettingRow(
                    title: "Models and local data",
                    consequence: "Review model downloads, database space, retained recordings, and their locations in one place."
                ) {
                    Button("Manage Storage") { coordinator.setSelection(.storage) }
                        .hushnoteButton(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hardware enumeration plugs into `availableDevices` without changing
    /// the persistence or visual contract established here.
    private struct MicrophoneInputControl: View {
        @Binding var selection: PreferredMicrophone?
        let availableDevices: [PreferredMicrophone]

        var body: some View {
            Menu {
                Button("System default") { selection = nil }
                ForEach(availableDevices) { device in
                    Button(device.displayName ?? "Microphone") { selection = device }
                }
                if availableDevices.isEmpty {
                    Text("Microphones appear after device discovery")
                }
            } label: {
                Text(selection?.displayName ?? "System default")
                    .lineLimit(1)
            }
            .hushnoteButton(.secondary)
            .accessibilityLabel("Microphone input")
            .accessibilityValue(selection?.displayName ?? "System default")
        }
    }

    private struct AppearanceModeControl: View {
        @AppStorage(AppPreferences.appearanceUserDefaultsKey)
        private var appearanceRawValue = AppearanceMode.system.rawValue

        private var selection: Binding<AppearanceMode> {
            Binding(
                get: {
                    AppearanceMode(rawValue: appearanceRawValue) ?? .system
                },
                set: { mode in
                    AppPreferences().appearance = mode
                    // Keep the observation source in sync so the root scene,
                    // Settings, and every open window update immediately.
                    appearanceRawValue = mode.rawValue
                }
            )
        }

        var body: some View {
            HushnoteSegmentedControl(
                options: AppearanceMode.allCases,
                selection: selection
            ) { mode in
                Text(mode.title)
                    .accessibilityLabel(mode.title)
            }
            .frame(width: 255)
            .accessibilityLabel("Appearance")
            .accessibilityValue(selection.wrappedValue.title)
        }
    }

    private func providerSettings(state: AppViewState, policy: AdaptiveLayoutPolicy) -> some View {
        settingsSection("INSIGHT PROVIDER") {
            ProviderInventory(
                selection: Binding(
                    get: { state.selectedProvider },
                    set: { coordinator.setSelectedProvider($0) }
                ),
                policy: policy
            ) {
                providerConfiguration(for: state.selectedProvider)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func providerConfiguration(for provider: InsightProviderChoice) -> some View {
        ProviderDisclosure(isLocal: provider.isLocal)

        if provider == .openAI || provider == .anthropic {
            APIKeyField(provider: provider)
        } else if provider == .chatGPT {
            Button("Connect ChatGPT") { Task { await coordinator.connectChatGPT() } }
                .hushnoteButton(.primary)
            Text("Uses Codex App Server’s managed login and Codex rate limits. It does not expose ChatGPT history.")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
        } else if let tool = provider.agentCLITool {
            AgentCLIStatusView(tool: tool)
            AgentCLIModelField(tool: tool)
        } else {
            DisclosureGroup("Advanced local configuration") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Path to llama-server executable", text: Binding(
                        get: { coordinator.localLlamaExecutablePath },
                        set: { coordinator.setLocalLlamaExecutablePath($0) }
                    ))
                    .textFieldStyle(HushnoteFieldStyle())
                    TextField("Path to GGUF model", text: Binding(
                        get: { coordinator.localModelPath },
                        set: { coordinator.setLocalModelPath($0) }
                    ))
                    .textFieldStyle(HushnoteFieldStyle())
                    Text("Hushnote launches the server on 127.0.0.1 only and stops it after the request.")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
                .padding(.top, 8)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HushnoteEyebrow(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A setting is a consequence and a control, not a row borrowed from the
/// system preference pane. The control remains a real Toggle or Button, so
/// keyboard and VoiceOver behavior are preserved.
private struct UtilitySettingRow<Accessory: View>: View {
    let title: String
    let consequence: String
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        consequence: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.consequence = consequence
        self.accessory = accessory()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                copy
                Spacer(minLength: 16)
                accessory
            }
            VStack(alignment: .leading, spacing: 12) {
                copy
                accessory
            }
        }
        .padding(.vertical, 11)
        .hushnoteBottomRule(opacity: 0.55)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            Text(consequence)
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

private struct UtilitySwitchStyle: ToggleStyle {
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

/// On larger canvases the provider is a product-owned inventory with an
/// adjacent detail panel. The compact control is deliberately a native Picker:
/// it gives a narrow window the same choices without a cramped button stack.
private struct ProviderInventory<Detail: View>: View {
    @Binding var selection: InsightProviderChoice
    let policy: AdaptiveLayoutPolicy
    @ViewBuilder let detail: Detail

    init(
        selection: Binding<InsightProviderChoice>,
        policy: AdaptiveLayoutPolicy,
        @ViewBuilder detail: () -> Detail
    ) {
        _selection = selection
        self.policy = policy
        self.detail = detail()
    }

    var body: some View {
        if policy == .compact {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Provider", selection: $selection) {
                    ForEach(InsightProviderChoice.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                detailPanel
            }
        } else {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(InsightProviderChoice.allCases) { provider in
                        Button {
                            selection = provider
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(selection == provider ? HushnoteTheme.vermilion : HushnoteTheme.rule)
                                    .frame(width: 6, height: 6)
                                Text(provider.rawValue)
                                    .font(.callout.weight(selection == provider ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(selection == provider ? HushnoteTheme.selectionSurface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(provider.rawValue)")
                        .accessibilityAddTraits(selection == provider ? .isSelected : [])
                    }
                }
                .frame(width: 194, alignment: .leading)

                detailPanel
                    .padding(.leading, 24)
                    .overlay(alignment: .leading) { Rectangle().fill(HushnoteTheme.rule.opacity(0.7)).frame(width: 1) }
            }
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selection.rawValue)
                .font(HushnoteTheme.Font.subsectionTitle)
            detail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModelStorageLocationCard: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Model storage", systemImage: "internaldrive")
                .font(.headline)
            DisclosureGroup("Location") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(coordinator.modelStorageDisplayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(coordinator.modelStorageDisplayPath, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        Button("Reveal") { coordinator.revealModelStorage() }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(HushnoteTheme.secondaryInk)

            HStack(spacing: 10) {
                Button("Choose Folder…") { coordinator.chooseModelStorageDirectory() }
                    .hushnoteButton(.secondary)
                if coordinator.modelStoragePaths.parentDirectory != nil {
                    Button("Use Default") { coordinator.resetModelStorageDirectory() }
                        .hushnoteButton(.secondary)
                }
            }

            if let progress = coordinator.modelStorageMigrationProgress {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(
                        value: Double(progress.completedItems),
                        total: Double(max(progress.totalItems, 1))
                    )
                    Text(progress.currentItem.map { "Copying \($0)…" } ?? "Finishing model copy…")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
                .frame(maxWidth: 480)
            } else if let queued = coordinator.queuedModelStoragePath {
                Label("Queued for \(queued)", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            } else if let status = coordinator.modelStorageStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }

            Text("A custom parent contains one Hushnote Models folder. Complete models can be copied when you switch; old files stay in place until you remove them yourself.")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .frame(maxWidth: 620, alignment: .leading)
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
                .foregroundStyle(HushnoteTheme.secondaryInk)

            if isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(tool.executableName)…")
                        .font(.caption)
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
            } else if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.vermilionInk)
                    .accessibilityLabel(problem)
            } else {
                Text("\(tool.displayName) is ready.")
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            }

            Button("Check again") { Task { await check() } }
                .hushnoteButton(.secondary)
                .disabled(isChecking)
        }
        .task(id: tool) { await check() }
    }

    private func check() async {
        isChecking = true
        let nextProblem = await coordinator.agentCLIUnavailability(tool)
        guard !Task.isCancelled else { return }
        problem = nextProblem
        isChecking = false
    }
}
