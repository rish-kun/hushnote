import Foundation
import XCTest
@testable import Hushnote

final class RecordingMarkerTests: XCTestCase {
    func testMarkerTypesHaveStableUserFacingTitles() {
        XCTAssertEqual(
            RecordingMarkerType.allCases.map(\.title),
            ["Important", "Decision", "Action", "Question", "Follow up"]
        )
        XCTAssertEqual(RecordingMarkerType.followUp.rawValue, "followUp")
    }

    func testMarkersRoundTripInMeetingTimelineOrder() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Marked meeting")
        try await store.saveMeeting(meeting)
        let firstSession = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(timeIntervalSince1970: 1_000),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        let secondSession = RecordingSession(
            meetingID: meeting.id,
            ordinal: 1,
            origin: .continued,
            wallStartedAt: Date(timeIntervalSince1970: 2_000),
            timelineStartMilliseconds: 60_000,
            state: .capturing
        )
        try await store.saveRecordingSession(firstSession)
        try await store.saveRecordingSession(secondSession)

        let later = RecordingMarker(
            meetingID: meeting.id,
            sessionID: secondSession.id,
            type: .followUp,
            timelineMilliseconds: 72_000,
            wallClockAt: Date(timeIntervalSince1970: 2_012)
        )
        let earlier = RecordingMarker(
            meetingID: meeting.id,
            sessionID: firstSession.id,
            type: .decision,
            timelineMilliseconds: 15_000,
            wallClockAt: Date(timeIntervalSince1970: 1_015)
        )
        try await store.saveRecordingMarker(later)
        try await store.saveRecordingMarker(earlier)

        let meetingMarkers = try await store.recordingMarkers(meetingID: meeting.id)
        let sessionMarkers = try await store.recordingMarkers(sessionID: secondSession.id)
        XCTAssertEqual(meetingMarkers, [earlier, later])
        XCTAssertEqual(sessionMarkers, [later])
    }

    func testMarkerSessionMustBelongToItsMeeting() async throws {
        let store = try MeetingStore(inMemory: ())
        let firstMeeting = Meeting(title: "First")
        let secondMeeting = Meeting(title: "Second")
        try await store.saveMeeting(firstMeeting)
        try await store.saveMeeting(secondMeeting)
        let session = RecordingSession(
            meetingID: firstMeeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        try await store.saveRecordingSession(session)

        do {
            try await store.saveRecordingMarker(.init(
                meetingID: secondMeeting.id,
                sessionID: session.id,
                type: .important,
                timelineMilliseconds: 1_000
            ))
            XCTFail("Expected cross-meeting marker parentage to be rejected")
        } catch let error as Hushnote.PersistenceError {
            guard case .invalidRecordingMarker = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNegativeTimelinePositionIsRejected() async throws {
        let store = try MeetingStore(inMemory: ())
        let meeting = Meeting(title: "Invalid marker")
        try await store.saveMeeting(meeting)
        let session = RecordingSession(
            meetingID: meeting.id,
            ordinal: 0,
            origin: .live,
            wallStartedAt: Date(),
            timelineStartMilliseconds: 0,
            state: .capturing
        )
        try await store.saveRecordingSession(session)

        do {
            try await store.saveRecordingMarker(.init(
                meetingID: meeting.id,
                sessionID: session.id,
                type: .question,
                timelineMilliseconds: -1
            ))
            XCTFail("Expected a negative marker position to be rejected")
        } catch let error as Hushnote.PersistenceError {
            guard case .invalidRecordingMarker = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
