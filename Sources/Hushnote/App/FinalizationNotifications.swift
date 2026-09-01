import Foundation
import UserNotifications

enum FinalizationNotificationKind: String, Equatable, Sendable {
    case ready
    case failed
}

struct FinalizationNotification: Equatable, Sendable {
    let meetingID: UUID
    let title: String
    let body: String
    let kind: FinalizationNotificationKind

    var categoryIdentifier: String {
        switch kind {
        case .ready: UserNotificationCategory.ready
        case .failed: UserNotificationCategory.failed
        }
    }
}

/// The app-facing seam around UserNotifications. Tests can record requests
/// without contacting the system notification daemon or prompting for access.
protocol FinalizationNotifying: Sendable {
    func requestAuthorization() async -> Bool
    func send(_ notification: FinalizationNotification) async throws
}

enum UserNotificationCategory {
    static let ready = "hushnote.finalization.ready"
    static let failed = "hushnote.finalization.failed"
    static let openSummary = "hushnote.finalization.open-summary"
    static let reviewTranscript = "hushnote.finalization.review-transcript"
    static let meetingIDKey = "hushnote.meeting-id"
}

/// The concrete adapter is deliberately isolated here so the rest of the app
/// never depends on UNMutableNotificationContent or notification categories.
final class UserNotificationFinalizationNotifier: FinalizationNotifying, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let openSummary = UNNotificationAction(
            identifier: UserNotificationCategory.openSummary,
            title: "Open Summary",
            options: [.foreground]
        )
        let reviewTranscript = UNNotificationAction(
            identifier: UserNotificationCategory.reviewTranscript,
            title: "Review Transcript",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: UserNotificationCategory.ready,
                actions: [openSummary, reviewTranscript],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: UserNotificationCategory.failed,
                actions: [reviewTranscript],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func send(_ notification: FinalizationNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.categoryIdentifier
        content.sound = .default
        content.userInfo = [
            UserNotificationCategory.meetingIDKey: notification.meetingID.uuidString,
        ]
        let request = UNNotificationRequest(
            identifier: "hushnote.finalization.\(notification.meetingID.uuidString)",
            content: content,
            trigger: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
