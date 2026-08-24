import AppKit
import SwiftUI

struct StorageDashboardView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @State private var recordingPendingRemoval: RecordingStorageUsage?

    var body: some View {
        ScrollView {
            AdaptivePageScaffold { policy in
                VStack(alignment: .leading, spacing: policy == .compact ? 24 : 30) {
                    header(policy: policy)
                    if let report = state.storageReport {
                        storageOverview(report, policy: policy)
                        cleanupInventory(report, policy: policy)
                    } else if state.isScanningStorage {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Calculating allocated storage…")
                                .foregroundStyle(HushnoteTheme.secondaryInk)
                        }
                        .padding(.vertical, 30)
                    } else {
                        HushnoteEmptyState(
                            title: "Storage has not been calculated",
                            message: "Refresh to measure models, retained recordings, and local app data.",
                            policy: policy
                        ) {
                            HushnoteGlyph(systemName: "internaldrive")
                        }
                    }
                }
            }
            .padding(.vertical, 36)
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

    private func header(policy: AdaptiveLayoutPolicy) -> some View {
        HushnotePageHeader(
            title: "Storage",
            subtitle: "Allocated space used by local models, recordings, and meeting data.",
            policy: policy
        ) {
            refreshButton
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
        .hushnoteButton(.secondary)
        .disabled(state.isScanningStorage)
    }

    @ViewBuilder
    private func storageOverview(_ report: StorageReport, policy: AdaptiveLayoutPolicy) -> some View {
        if policy == .wide {
            HStack(alignment: .top, spacing: 42) {
                allocationSummary(report)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 18) {
                    ModelStorageLocationCard()
                    scanHealth(report)
                }
                .frame(width: 330, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                allocationSummary(report)
                ModelStorageLocationCard()
                scanHealth(report)
            }
        }
    }

    private func allocationSummary(_ report: StorageReport) -> some View {
        let total = report.models.allocatedBytes
            + report.recordings.allocatedBytes
            + report.database.allocatedBytes
            + report.other.allocatedBytes

        return VStack(alignment: .leading, spacing: 14) {
            HushnoteEyebrow("Allocated on this Mac")
            HushnoteMetric(value: StorageByteText.string(total))
            StorageAllocationBar(
                total: total,
                categories: [
                    StorageAllocation(title: "Models", usage: report.models, color: HushnoteTheme.moss),
                    StorageAllocation(title: "Recordings", usage: report.recordings, color: HushnoteTheme.vermilion),
                    StorageAllocation(title: "Database", usage: report.database, color: HushnoteTheme.inkFill),
                    StorageAllocation(title: "Other", usage: report.other, color: HushnoteTheme.rule)
                ]
            )
            Text("Includes local models, retained recordings, the meeting database, and support files.")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func scanHealth(_ report: StorageReport) -> some View {
        if report.isPartial {
            partialScanNotice(report)
        } else {
            HushnoteStatusLine(text: "Last scan could read every Hushnote folder.", tone: .good)
        }
    }

    private func partialScanNotice(_ report: StorageReport) -> some View {
        HushnoteStatusLine(
            text: "Some folders could not be read. Totals include everything Hushnote could inspect and may be lower than the space actually used.",
            tone: .warning
        )
        .padding(.vertical, 9)
        .accessibilityHint("The scan reported (report.issues.count) access issues")
    }

    private func cleanupInventory(_ report: StorageReport, policy: AdaptiveLayoutPolicy) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HushnoteEyebrow("Cleanup inventory")
            modelDetails(report.modelDetails, policy: policy)
            recordingDetails(report.recordingDetails, policy: policy)
            localDataDetails(report, policy: policy)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func modelDetails(_ details: [ModelStorageUsage], policy: AdaptiveLayoutPolicy) -> some View {
        let visible = details.filter { $0.allocatedBytes > 0 || $0.isPartial }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
        if !visible.isEmpty {
            HushnoteSection(title: "Model storage") {
                ForEach(visible, id: \.modelID) { model in
                    detailRow(
                        title: model.displayName,
                        detail: model.url.path,
                        allocatedBytes: model.allocatedBytes,
                        isPartial: model.isPartial,
                        policy: policy
                    ) {
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
                // `.active` badge tone is reserved for the meeting recording right
                // now (filled vermilion); "the model currently in use" is a
                // different, calmer state, so it takes `.positive` instead.
                HushnoteBadge(title: "Active", tone: .positive)
            } else {
                Button("Remove…", role: .destructive) { coordinator.promptToRemoveModel(model) }
                    .hushnoteButton(.destructive)
                    .disabled(!coordinator.canChangeModelStorage)
            }
        } else if usage.modelID == "speaker-diarization" {
            Button("Remove…", role: .destructive) { coordinator.promptToRemoveDiarizationModels() }
                .hushnoteButton(.destructive)
                .disabled(!coordinator.canChangeModelStorage)
        }
    }

    @ViewBuilder
    private func recordingDetails(_ details: [RecordingStorageUsage], policy: AdaptiveLayoutPolicy) -> some View {
        let visible = details.sorted { $0.allocatedBytes > $1.allocatedBytes }
        HushnoteSection(title: "Retained recordings") {
            if visible.isEmpty {
                Text("No retained or recoverable recordings are using storage.")
                    .foregroundStyle(HushnoteTheme.secondaryInk)
            } else {
                ForEach(visible, id: \.meetingID) { recording in
                    detailRow(
                        title: recording.title,
                        detail: recording.url.path,
                        allocatedBytes: recording.allocatedBytes,
                        isPartial: recording.isPartial,
                        policy: policy
                    ) {
                        if state.storageDeletingRecordingIDs.contains(recording.meetingID) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Remove Audio…", role: .destructive) {
                                recordingPendingRemoval = recording
                            }
                            .hushnoteButton(.destructive)
                            .disabled(!coordinator.canRemoveRecordingAudio(meetingID: recording.meetingID))
                            .help(cleanupHelp(for: recording.meetingID))
                        }
                    }
                }
            }
        }
    }

    private func localDataDetails(_ report: StorageReport, policy: AdaptiveLayoutPolicy) -> some View {
        HushnoteSection(title: "Local app data") {
            if let database = report.databaseDetails.first {
                detailRow(
                    title: "Meeting database",
                    detail: database.databaseURL.path,
                    allocatedBytes: database.allocatedBytes,
                    isPartial: database.isPartial,
                    policy: policy
                )
            }
            detailRow(
                title: "Other Application Support files",
                detail: coordinator.applicationDataPath,
                allocatedBytes: report.other.allocatedBytes,
                isPartial: report.other.isPartial,
                policy: policy
            )
            Text("Other excludes the database and recording folders listed above.")
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
        }
    }

    /// A cleanup-inventory row with no trailing action, e.g. the database entry.
    private func detailRow(
        title: String,
        detail: String,
        allocatedBytes: Int64,
        isPartial: Bool,
        policy: AdaptiveLayoutPolicy
    ) -> some View {
        detailRow(title: title, detail: detail, allocatedBytes: allocatedBytes, isPartial: isPartial, policy: policy) {
            EmptyView()
        }
    }

    private func detailRow<Trailing: View>(
        title: String,
        detail: String,
        allocatedBytes: Int64,
        isPartial: Bool,
        policy: AdaptiveLayoutPolicy,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HushnoteInventoryRow(policy: policy) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HushnoteTheme.ink)
                        if isPartial {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(HushnoteTheme.vermilionInk)
                        }
                    }
                    Spacer(minLength: 10)
                    Text(StorageByteText.string(allocatedBytes))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(HushnoteTheme.secondaryInk)
                }
                HushnotePathDisclosure(path: detail)
            }
        } trailing: {
            trailing()
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

private struct StorageAllocation: Identifiable {
    let title: String
    let usage: StorageCategoryUsage
    let color: Color

    var id: String { title }
}

private struct StorageAllocationBar: View {
    let total: Int64
    let categories: [StorageAllocation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(categories.filter { $0.usage.allocatedBytes > 0 }) { category in
                        Rectangle()
                            .fill(category.color)
                            .frame(width: segmentWidth(category, in: proxy.size.width))
                    }
                }
                .clipShape(Capsule(style: .continuous))
            }
            .frame(height: 12)
            .background(HushnoteTheme.rule.opacity(0.32), in: Capsule(style: .continuous))

            FlowLayout(spacing: 12) {
                ForEach(categories) { category in
                    HStack(spacing: 5) {
                        Circle().fill(category.color).frame(width: 7, height: 7)
                        Text("\(category.title) \(StorageByteText.string(category.usage.allocatedBytes))")
                    }
                    .font(.caption)
                    .foregroundStyle(HushnoteTheme.secondaryInk)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func segmentWidth(_ category: StorageAllocation, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return available * CGFloat(Double(category.usage.allocatedBytes) / Double(total))
    }

    private var accessibilityText: String {
        let values = categories.map { "\($0.title), \(StorageByteText.string($0.usage.allocatedBytes))" }
        return "Storage allocation. " + values.joined(separator: ". ")
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var lineWidth: CGFloat = 0
        var height: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > width {
                height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth == 0 ? 0 : spacing) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? lineWidth, height: height + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + spacing + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }
            if point.x > bounds.minX { point.x += spacing }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}

enum StorageByteText {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
