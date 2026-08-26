import AppKit
import SwiftUI

/// Everything this Mac has published, and the only place it can be withdrawn.
///
/// There are no accounts and no web dashboard: a share is owned by whoever
/// holds the device token in this Mac's Keychain. That makes this route the
/// entire management surface for the feature, which is why it states the
/// consequence of losing that token rather than leaving it to a support page.
struct SharedLinksView: View {
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    private var shares: [MeetingShare] {
        state.meetingShares.values.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        AdaptivePageScaffold { policy in
            VStack(alignment: .leading, spacing: 0) {
                HushnotePageHeader(
                    title: "Shared",
                    subtitle: "Links you have published. Anyone holding one can read what it includes.",
                    policy: policy
                )

                if shares.isEmpty {
                    HushnoteEmptyState(
                        title: "Nothing shared",
                        message: "Share a meeting from its header to publish a link."
                    ) {
                        HushnoteGlyph(systemName: "link")
                    }
                    .padding(.top, 40)
                } else {
                    ForEach(shares) { share in
                        SharedLinkRow(share: share, policy: policy)
                    }
                    ownershipNote.padding(.top, 26)
                }
            }
            .padding(.horizontal, policy.gutter)
            .padding(.vertical, 26)
        }
    }

    /// Said here because there is nowhere else to say it. A share cannot be
    /// recovered from a backup, an email address, or a support request.
    private var ownershipNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            HushnoteEyebrow("Ownership")
            Text("""
                These links are owned by a key held in this Mac's Keychain. \
                Restoring this Mac without it leaves the links readable and \
                impossible to withdraw from here.
                """)
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SharedLinkRow: View {
    let share: MeetingShare
    let policy: AdaptiveLayoutPolicy
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator

    private var title: String {
        state.meetings.first(where: { $0.id == share.meetingID })?.title ?? "Meeting"
    }

    /// Optional because `ShareLinkPolicy` validates the id rather than trusting
    /// it. A row whose stored id is not a well-formed share id is a corrupt
    /// local record; it still shows, so the link can be revoked.
    private var link: URL? {
        ShareLinkPolicy.url(shareID: share.shareID, origin: ShareService.origin())
    }

    var body: some View {
        HushnoteInventoryRow(policy: policy) {
            EmptyView()
        } content: {
            HushnoteRowIdentity(
                title: title,
                excerpt: link?.absoluteString ?? "Unreadable link",
                metadata: [includesSummary]
            ) {
                if share.hasPassword {
                    HushnoteBadge(title: "Password", tone: .positive)
                }
            }
        } trailing: {
            HStack(spacing: 10) {
                if state.sharesInFlight.contains(share.meetingID) {
                    ProgressView().controlSize(.small)
                } else {
                    if let link {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                        .hushnoteButton(.quiet)
                    }
                    Button("Open") { coordinator.setSelection(.meeting(share.meetingID)) }
                        .hushnoteButton(.quiet)
                    Button("Revoke") {
                        Task { await coordinator.revokeShare(meetingID: share.meetingID) }
                    }
                    .hushnoteButton(.destructive)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let error = share.lastError {
                HushnoteStatusLine(text: error, tone: .warning)
                    .padding(.bottom, 4)
            }
        }
    }

    /// Which of the three a reader will actually see. A share is only as
    /// private as the parts left out of it, so this is not decoration.
    private var includesSummary: String {
        var parts: [String] = []
        if share.includes.transcript { parts.append("Transcript") }
        if share.includes.notes { parts.append("Notes") }
        if share.includes.summary { parts.append("Summary") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}
