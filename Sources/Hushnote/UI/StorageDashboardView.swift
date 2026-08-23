import SwiftUI

struct StorageDashboardView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var recordingPendingRemoval: RecordingStorageUsage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let report = state.storageReport {
                    categoryCards(report)
                    if report.isPartial { partialScanNotice(report) }
                    ModelStorageLocationCard()
                    modelDetails(report.modelDetails)
                    recordingDetails(report.recordingDetails)
                    localDataDetails(report)
                } else if state.isScanningStorage {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Calculating allocated storage…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 30)
                } else {
                    ContentUnavailableView(
                        "Storage has not been calculated",
                        systemImage: "internaldrive",
                        description: Text("Refresh to measure models, retained recordings, and local app data.")
                    )
                }
            }
            .pageChrome()
        }
        .task {
            coordinator.refreshInstalledModels()
            await coordinator.refreshStorageReport()
        }
        .alert(
            "Remove retained recording?",
            isPresented: Binding(
                get: { recordingPendingRemoval != nil },
                set: { if !$0 { recordingPendingRemoval = nil } }
            ),
            presenting: recordingPendingRemoval
        ) { recording in
            Button("Remove Audio", role: .destructive) {
                recordingPendingRemoval = nil
                Task { await coordinator.removeRecordingAudio(meetingID: recording.meetingID) }
            }
            Button("Cancel", role: .cancel) { recordingPendingRemoval = nil }
        } message: { recording in
            Text("This frees (StorageByteText.string(recording.allocatedBytes)). The meeting note, transcript, and summaries remain available.")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                headerText
                Spacer(minLength: 18)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 14) {
                headerText
                refreshButton
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storage")
                .font(HushnoteTheme.Font.pageTitle)
            Text("Allocated space used by local models, recordings, and meeting data.")
                .foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await coordinator.refreshStorageReport() }
        } label: {
            if state.isScanningStorage {
                Label("Refreshing…", systemImage: "arrow.clockwise")
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .disabled(state.isScanningStorage)
    }

    private func categoryCards(_ report: StorageReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StorageCategoryCard(title: "Models", symbol: "cpu", usage: report.models)
            StorageCategoryCard(title: "Recordings", symbol: "waveform", usage: report.recordings)
            StorageCategoryCard(title: "Database", symbol: "cylinder", usage: report.database)
            StorageCategoryCard(title: "Other", symbol: "folder", usage: report.other)
        }
    }

    private func partialScanNotice(_ report: StorageReport) -> some View {
        Label {
            Text("Some folders could not be read. Totals include everything Hushnote could inspect and may be lower than the space actually used.")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(HushnoteTheme.vermilionInk)
        .padding(12)
        .background(HushnoteTheme.vermilion.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHint("The scan reported (report.issues.count) access issues")
    }

    @ViewBuilder
    private func modelDetails(_ details: [ModelStorageUsage]) -> some View {
        let visible = details.filter { $0.allocatedBytes > 0 || $0.isPartial }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
        if !visible.isEmpty {
            StorageSection(title: "MODEL STORAGE") {
                ForEach(visible, id: \.modelID) { model in
                    HStack(alignment: .center, spacing: 14) {
                        StorageDetailRow(
                            title: model.displayName,
                            detail: model.url.path,
                            allocatedBytes: model.allocatedBytes,
                            isPartial: model.isPartial
                        )
                        modelCleanupControl(model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelCleanupControl(_ usage: ModelStorageUsage) -> some View {
        if let model = SpeechModelCatalog.model(id: usage.modelID) {
            let isActive = model.id == SpeechModelResolver.model(named: state.draft.liveModel).id
                || model.id == SpeechModelResolver.model(named: state.draft.finalModel).id
            if isActive {
                Text("ACTIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(HushnoteTheme.moss)
            } else {
                Button("Remove…", role: .destructive) { coordinator.promptToRemoveModel(model) }
                    .buttonStyle(.bordered)
                    .disabled(!coordinator.canChangeModelStorage)
            }
        } else if usage.modelID == "speaker-diarization" {
            Button("Remove…", role: .destructive) { coordinator.promptToRemoveDiarizationModels() }
                .buttonStyle(.bordered)
                .disabled(!coordinator.canChangeModelStorage)
        }
    }

    @ViewBuilder
    private func recordingDetails(_ details: [RecordingStorageUsage]) -> some View {
        let visible = details.sorted { $0.allocatedBytes > $1.allocatedBytes }
        StorageSection(title: "RETAINED RECORDINGS") {
            if visible.isEmpty {
                Text("No retained or recoverable recordings are using storage.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.meetingID) { recording in
                    HStack(alignment: .center, spacing: 14) {
                        StorageDetailRow(
                            title: recording.title,
                            detail: recording.url.path,
                            allocatedBytes: recording.allocatedBytes,
                            isPartial: recording.isPartial
                        )
                        if state.storageDeletingRecordingIDs.contains(recording.meetingID) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Remove Audio…", role: .destructive) {
                                recordingPendingRemoval = recording
                            }
                            .buttonStyle(.bordered)
                            .disabled(!coordinator.canRemoveRecordingAudio(meetingID: recording.meetingID))
                            .help(cleanupHelp(for: recording.meetingID))
                        }
                    }
                }
            }
        }
    }

    private func localDataDetails(_ report: StorageReport) -> some View {
        StorageSection(title: "LOCAL APP DATA") {
            if let database = report.databaseDetails.first {
                StorageDetailRow(
                    title: "Meeting database",
                    detail: database.databaseURL.path,
                    allocatedBytes: database.allocatedBytes,
                    isPartial: database.isPartial
                )
            }
            StorageDetailRow(
                title: "Other Application Support files",
                detail: coordinator.applicationDataPath,
                allocatedBytes: report.other.allocatedBytes,
                isPartial: report.other.isPartial
            )
            Text("Other excludes the database and recording folders listed above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cleanupHelp(for meetingID: UUID) -> String {
        guard let meeting = (state.meetings + state.recentlyDeletedMeetings)
            .first(where: { $0.id == meetingID }) else { return "This meeting is unavailable." }
        if meeting.status == .interrupted || meeting.status == .failed {
            return "This recording is needed to recover the meeting."
        }
        if state.recordingPhase.isBusy { return "Wait for recording and finalization to finish." }
        return "Remove the recording but keep the meeting note, transcript, and summaries."
    }
}

private struct StorageCategoryCard: View {
    let title: String
    let symbol: String
    let usage: StorageCategoryUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(StorageByteText.string(usage.allocatedBytes))
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(usage.isPartial ? "Partial total" : itemText)
                .font(.caption)
                .foregroundStyle(usage.isPartial ? HushnoteTheme.vermilionInk : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(HushnoteTheme.paperRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(HushnoteTheme.rule.opacity(0.7)) }
    }

    private var itemText: String {
        usage.itemCount == 1 ? "1 item" : "\(usage.itemCount) items"
    }
}

private struct StorageDetailRow: View {
    let title: String
    let detail: String
    let allocatedBytes: Int64
    let isPartial: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if isPartial {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(HushnoteTheme.vermilionInk)
                    }
                }
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Text(StorageByteText.string(allocatedBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }
}

private struct StorageSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1.3)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum StorageByteText {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
