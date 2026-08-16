import Foundation
import Testing
@testable import Hushnote

/// The formatter had no hours field: `String(format: "%02d:%02d", total / 60,
/// total % 60)`. A two-hour-fifteen meeting rendered as `135:00` in the meeting
/// list, the workspace header, the recording pill, the menu bar and the
/// exported Markdown, and VoiceOver read it aloud as "one hundred thirty five
/// colon zero zero". `MeetingExporter.srtTime` already had the right logic, so
/// this was the outlier rather than a missing idea.
@Suite("Duration text")
struct DurationTextTests {
    @Test("A clock reading carries hours once there are any")
    func clockBoundaries() {
        #expect(DurationText.clock(0) == "00:00")
        #expect(DurationText.clock(59) == "00:59")
        #expect(DurationText.clock(60) == "01:00")
        #expect(DurationText.clock(3_599) == "59:59")
        #expect(DurationText.clock(3_600) == "1:00:00")
        #expect(DurationText.clock(3_912) == "1:05:12")
        #expect(DurationText.clock(8_100) == "2:15:00")
    }

    /// The bug, stated as the case that produced it.
    @Test("Two hours fifteen is not a hundred and thirty five minutes")
    func theReportedCase() {
        #expect(DurationText.clock(8_100) != "135:00")
        #expect(DurationText.clock(8_100) == "2:15:00")
    }

    @Test("A duration below zero is not rendered as one")
    func negativeDurationsClampToZero() {
        #expect(DurationText.clock(-1) == "00:00")
        #expect(DurationText.spoken(-90) == "0 seconds")
    }

    /// A screen reader gets units, not punctuation.
    @Test("The spoken form names its units")
    func spokenBoundaries() {
        #expect(DurationText.spoken(0) == "0 seconds")
        #expect(DurationText.spoken(59) == "59 seconds")
        #expect(DurationText.spoken(3_600) == "1 hour")
        #expect(DurationText.spoken(3_912) == "1 hour 5 minutes 12 seconds")
        #expect(DurationText.spoken(8_100) == "2 hours 15 minutes")
    }

    @Test("The spoken form is singular where it should be")
    func spokenPluralisation() {
        #expect(DurationText.spoken(1) == "1 second")
        #expect(DurationText.spoken(60) == "1 minute")
        #expect(DurationText.spoken(61) == "1 minute 1 second")
        #expect(DurationText.spoken(7_200) == "2 hours")
    }

    /// An empty component is dropped rather than spoken as a zero.
    @Test("Zero components are left out")
    func spokenSkipsEmptyComponents() {
        #expect(DurationText.spoken(3_660) == "1 hour 1 minute")
        #expect(DurationText.spoken(3_601) == "1 hour 1 second")
    }

    /// Fractional seconds arrive from segment start times in milliseconds and
    /// must not round a timestamp forward past the word it points at.
    @Test("Fractions truncate rather than round")
    func fractionsTruncate() {
        #expect(DurationText.clock(59.9) == "00:59")
        #expect(DurationText.clock(3_599.999) == "59:59")
    }
}
