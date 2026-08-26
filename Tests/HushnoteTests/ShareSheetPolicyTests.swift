import Foundation
import Testing
@testable import Hushnote

/// The share sheet's toggles are the only privacy control the feature has: a
/// share is republished from the current meeting whenever what it includes
/// changes, so content left out of a share is the only content guaranteed never
/// to leave the Mac. These are the rules that guard publishing.
@Suite("Share sheet rules")
struct ShareSheetPolicyTests {
    private let all = ShareIncludes(transcript: true, notes: true, summary: true)
    private let none = ShareIncludes(transcript: false, notes: false, summary: false)

    /// Publishing an empty page under a real link is worse than refusing: the
    /// link still exists, still resolves, and shows nothing.
    @Test("Nothing selected is not a share")
    func nothingSelected() {
        #expect(ShareSheetPolicy.refusal(includes: none, password: "") == .nothingSelected)
        #expect(ShareSheetPolicy.refusal(includes: none, password: "correcthorse") == .nothingSelected)
    }

    /// A blank field means "no password", which is a choice. A four-character
    /// one is an attempt at protection that would not provide any -- the server
    /// throttles guessing, which buys time against a dictionary but nothing
    /// against something a person can simply type.
    @Test("A short password is refused, but no password is allowed")
    func passwordLength() {
        #expect(ShareSheetPolicy.refusal(includes: all, password: "") == nil)
        #expect(ShareSheetPolicy.refusal(includes: all, password: "short") == .passwordTooShort)
        #expect(ShareSheetPolicy.refusal(includes: all, password: "correcthorse") == nil)
    }

    /// Nothing selected outranks a short password: fix the thing that makes the
    /// share meaningless before the thing that makes it weak.
    @Test("The refusal that matters most is the one reported")
    func refusalOrder() {
        #expect(ShareSheetPolicy.refusal(includes: none, password: "abc") == .nothingSelected)
    }

    /// A row of switch positions is not a sentence anyone reads carefully, and
    /// this is the last thing shown before a transcript goes on the internet.
    @Test("The audience summary names what a reader would actually see")
    func audienceSummary() {
        let unprotected = ShareSheetPolicy.audienceSummary(
            includes: ShareIncludes(transcript: true, notes: true, summary: false),
            hasPassword: false
        )
        #expect(unprotected.contains("the transcript"))
        #expect(unprotected.contains("your notes"))
        #expect(!unprotected.contains("the summary"))
        // The property that makes a link dangerous, said once.
        #expect(unprotected.contains("Forwarding"))

        let protected = ShareSheetPolicy.audienceSummary(includes: .transcriptOnly, hasPassword: true)
        #expect(protected.contains("password"))
        #expect(!protected.contains("Forwarding"))
    }

    @Test("An empty selection says so rather than describing an empty audience")
    func emptySummary() {
        #expect(ShareSheetPolicy.audienceSummary(includes: none, hasPassword: false)
            .contains("nothing to publish"))
    }
}

/// The `Shared` route is only offered once something is shared, so a persisted
/// selection pointing at it must resolve away when nothing is -- otherwise it
/// is an empty page with no sidebar row pointing at it, reachable only by
/// having been there last launch.
@Suite("Shared destination resolution")
struct SharedDestinationTests {
    @Test("Shared resolves to the library when nothing is shared")
    func staleSharedResolves() {
        #expect(
            AppViewState.resolvedSidebarDestination(
                .shared, meetingIDs: [], folderIDs: [], hasShares: false
            ) == .meetings
        )
    }

    @Test("Shared survives when there is something to show")
    func liveSharedSurvives() {
        #expect(
            AppViewState.resolvedSidebarDestination(
                .shared, meetingIDs: [], folderIDs: [], hasShares: true
            ) == .shared
        )
    }
}
