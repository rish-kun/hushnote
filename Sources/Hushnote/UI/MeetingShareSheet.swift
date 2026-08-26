import AppKit
import SwiftUI

/// What the share sheet will and will not let you do.
///
/// Pure, so the rules that decide whether a meeting can be published are
/// testable without driving a sheet.
enum ShareSheetPolicy {
    /// A password shorter than this is theatre. The server throttles guesses,
    /// which buys time against a dictionary attack but nothing against a
    /// four-character one someone can simply try by hand.
    static let minimumPasswordLength = 8

    enum Refusal: Equatable, Sendable {
        case nothingSelected
        case passwordTooShort
    }

    /// - Returns: why publishing is refused, or `nil` when it may proceed.
    nonisolated static func refusal(
        includes: ShareIncludes,
        password: String
    ) -> Refusal? {
        if includes.isEmpty { return .nothingSelected }
        // An empty field means "no password", which is allowed. A short one is
        // an attempt at protection that would not provide any.
        if !password.isEmpty, password.count < minimumPasswordLength {
            return .passwordTooShort
        }
        return nil
    }

    nonisolated static func message(for refusal: Refusal) -> String {
        switch refusal {
        case .nothingSelected:
            "Choose at least one of transcript, notes or summary."
        case .passwordTooShort:
            "Use at least \(minimumPasswordLength) characters, or leave it blank."
        }
    }

    /// Plain-language summary of what a reader of this link would see. Shown
    /// before publishing, because the toggles are the only privacy control the
    /// feature has and a list of switch positions is not a sentence anyone
    /// reads carefully.
    nonisolated static func audienceSummary(
        includes: ShareIncludes,
        hasPassword: Bool
    ) -> String {
        var parts: [String] = []
        if includes.transcript { parts.append("the transcript") }
        if includes.notes { parts.append("your notes") }
        if includes.summary { parts.append("the summary") }

        guard !parts.isEmpty else { return "Nothing is selected, so there is nothing to publish." }

        let list = ListFormatter.localizedString(byJoining: parts)
        return hasPassword
            ? "Anyone with the link and the password can read \(list)."
            : "Anyone with the link can read \(list). Forwarding the link forwards the access."
    }
}

/// Publishing a meeting, and the one place the cost of doing so is stated.
struct MeetingShareSheet: View {
    let meetingID: UUID
    @Environment(AppViewState.self) private var state
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var includes = ShareIncludes.transcriptOnly
    @State private var password = ""
    @State private var didLoadExisting = false

    private var share: MeetingShare? { state.meetingShares[meetingID] }
    private var isBusy: Bool { state.sharesInFlight.contains(meetingID) }

    private var refusal: ShareSheetPolicy.Refusal? {
        ShareSheetPolicy.refusal(includes: includes, password: password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HushnoteRule()

            VStack(alignment: .leading, spacing: 22) {
                disclosure
                contentToggles
                passwordField
                if let share { publishedLink(share) }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)

            HushnoteRule()
            actions
        }
        .frame(width: 520)
        .background(HushnoteTheme.paper)
        .task {
            guard !didLoadExisting else { return }
            didLoadExisting = true
            if let share { includes = share.includes }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(share == nil ? "Share this meeting" : "Shared")
                .font(HushnoteTheme.Font.sectionTitle)
            Text(ShareSheetPolicy.audienceSummary(
                includes: includes,
                hasPassword: !password.isEmpty || share?.hasPassword == true
            ))
            .font(.callout)
            .foregroundStyle(HushnoteTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    /// Hushnote's front page says local-first. This is the one place that stops
    /// being true, so it is said here rather than discovered later.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            HushnoteBadge(title: "Leaves this Mac", tone: .alert)
            Text("""
                The selected content is uploaded and stored so a browser can \
                read it. Everything else about this meeting — the audio, and \
                anything you do not select — stays on this Mac.
                """)
                .font(.caption)
                .foregroundStyle(HushnoteTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contentToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            HushnoteEyebrow("Include")
            Toggle("Transcript", isOn: $includes.transcript)
            Toggle("Notes", isOn: $includes.notes)
            Toggle("Summary and cited insights", isOn: $includes.summary)
        }
        .toggleStyle(HushnoteToggleStyle())
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HushnoteEyebrow(share?.hasPassword == true ? "Change password" : "Password")
            SecureField(
                share?.hasPassword == true ? "Leave blank to keep the current one" : "Optional",
                text: $password
            )
            .hushnoteField()
            if let refusal, refusal == .passwordTooShort {
                HushnoteStatusLine(text: ShareSheetPolicy.message(for: refusal), tone: .warning)
            }
        }
    }

    @ViewBuilder
    private func publishedLink(_ share: MeetingShare) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HushnoteEyebrow("Link")
            HStack(spacing: 10) {
                Text(linkText(share))
                    .font(.caption.monospaced())
                    .foregroundStyle(HushnoteTheme.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Copy") { copy(share) }
                    .hushnoteButton(.secondary)
            }
            if let error = share.lastError {
                HushnoteStatusLine(text: error, tone: .warning)
            } else if share.syncedChecksum == nil {
                HushnoteStatusLine(text: "Not published yet", tone: .neutral)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if share != nil {
                Button("Revoke") {
                    Task {
                        await coordinator.revokeShare(meetingID: meetingID)
                        dismiss()
                    }
                }
                .hushnoteButton(.destructive)
                .disabled(isBusy)
            }
            Spacer()
            Button("Done") { dismiss() }
                .hushnoteButton(.quiet)
            Button(primaryTitle) {
                Task {
                    await coordinator.publishShare(
                        meetingID: meetingID,
                        includes: includes,
                        password: password.isEmpty ? nil : password
                    )
                    password = ""
                }
            }
            .hushnoteButton(.primary)
            .disabled(isBusy || refusal != nil)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }

    private var primaryTitle: String {
        if isBusy { return "Working…" }
        return share == nil ? "Create link" : "Update"
    }

    private func linkText(_ share: MeetingShare) -> String {
        ShareLinkPolicy.url(shareID: share.shareID, origin: ShareService.origin())?
            .absoluteString ?? "Unreadable link"
    }

    private func copy(_ share: MeetingShare) {
        guard let url = ShareLinkPolicy.url(shareID: share.shareID, origin: ShareService.origin())
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
