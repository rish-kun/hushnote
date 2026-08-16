import Foundation
import Testing
@testable import Hushnote

/// Every transcript row built `TimestampButton(seconds: line.start) {}` -- a
/// focusable control with an empty action, labelled "Jump to ...". Citations did
/// the same. On a three-thousand-line transcript that is three thousand
/// keyboard stops that each advertise a seek to a screen-reader user and then
/// do nothing. There is no playback engine, so the honest form is not a button.
@Suite("Timestamp affordance")
struct TimestampAffordanceTests {
    @Test("A timestamp with nowhere to go does not offer to go there")
    func staticTimestampDoesNotPromiseASeek() {
        let label = TimestampButton.accessibilityLabel(at: 3_912, isInteractive: false)

        #expect(label.contains("Jump") == false)
        #expect(label == "At 1 hour 5 minutes 12 seconds")
    }

    @Test("A timestamp wired to an action still offers it")
    func interactiveTimestampPromisesASeek() {
        #expect(
            TimestampButton.accessibilityLabel(at: 90, isInteractive: true)
                == "Jump to 1 minute 30 seconds"
        )
    }

    /// The label is spoken, so it carries units rather than a clock face.
    @Test("The label speaks units, not punctuation")
    func labelIsSpokenNotPunctuated() {
        #expect(TimestampButton.accessibilityLabel(at: 8_100, isInteractive: false).contains(":") == false)
    }

    /// The rendered text is still the compact clock reading -- only the spoken
    /// label differs.
    @Test("The visible text stays a clock reading")
    func visibleTextIsUnchanged() {
        #expect(DurationText.clock(3_912) == "1:05:12")
    }
}
