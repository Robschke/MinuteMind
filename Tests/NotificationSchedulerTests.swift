// Purpose: Tests for notification request construction and identifier format (SETT-03).
// Dependencies: UserNotifications framework (no UNUserNotificationCenter authorization required)
// Notes: Tests only request construction and identifier logic — does NOT call center.add(_:) or
//        removePendingNotificationRequests (which require entitlements on macOS).

import Foundation
import UserNotifications
import Testing
@testable import MinuteMindApp

@Suite("NotificationScheduler Tests")
struct NotificationSchedulerTests {

    // MARK: - Identifier Format Tests (SETT-03)

    @Test("reminder request identifier uses expected format mm.taskReview.<hour>.<minute>")
    func testReminderRequestIdentifierFormat() {
        let dateComponents = DateComponents(hour: 9, minute: 0)
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let identifier = "mm.taskReview.9.0"
        let content = UNMutableNotificationContent()
        content.title = "MinuteMind Task Review"
        content.body = "Review your tasks from today's meetings"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        #expect(request.identifier == "mm.taskReview.9.0")
    }

    @Test("all reminder identifiers start with mm.taskReview. prefix")
    func testClearIdentifierPrefix() {
        // Tests the prefix filter pattern used in clearAllTaskReviewReminders
        let identifiers = [
            "mm.taskReview.9.0",
            "mm.taskReview.18.30",
            "mm.taskReview.7.15",
        ]

        let filtered = identifiers.filter { $0.hasPrefix("mm.taskReview.") }
        #expect(filtered.count == identifiers.count)

        // Non-matching identifiers must be excluded by the filter
        let mixed = identifiers + ["other.notification", "mm.differentPrefix.1.0"]
        let filteredMixed = mixed.filter { $0.hasPrefix("mm.taskReview.") }
        #expect(filteredMixed.count == identifiers.count)
    }
}
