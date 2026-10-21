import Foundation
import Observation
import UserNotifications
import XDictContract

/// **When a reminder is worth delivering** (plan-history-and-learning §5.4): the core says how many cards are due and
/// when the next one falls due; the shell decides the moment. Kept pure, so any summary and any hour is a test.
public enum ReviewReminderPlan {
    /// What the notification says (`due`: cards due now; 0 for one that falls due later) and when it fires.
    public struct Reminder: Equatable, Sendable {
        public let fireAt: Date
        public let due: UInt64

        public init(fireAt: Date, due: UInt64) {
            self.fireAt = fireAt
            self.due = due
        }
    }

    /// A card due now is reminded a minute from now rather than mid-look-up; a card due later, at its moment, never
    /// sooner than that minute. Nothing scheduled, nothing to remind.
    public static func next(summary: ReviewSummary, now: Date) -> Reminder? {
        let earliest = now.addingTimeInterval(delay)
        if summary.due > 0 { return Reminder(fireAt: earliest, due: summary.due) }
        guard let nextDue = summary.nextDue else { return nil }
        let at = Date(timeIntervalSince1970: TimeInterval(nextDue))
        return Reminder(fireAt: max(at, earliest), due: 0)
    }

    /// The soonest a reminder fires after it is planned.
    public static let delay: TimeInterval = 60
}

/// What delivering a reminder needs of the system, behind a protocol so the app's tests watch what would be scheduled.
/// The methods are nonisolated: the values are built and handed over in one call, never across an actor.
public protocol ReminderDelivery: Sendable {
    func isAuthorized() async -> Bool
    func requestAuthorization() async -> Bool
    func schedule(_ reminder: ReviewReminderPlan.Reminder) async
    func cancel() async
}

/// **The system's notification centre** (plan §5.4): one pending request, replaced on every plan, removed when the reader
/// turns reminders off or nothing is due. A run with no bundle — `swift test`, a development instrument — does nothing.
public struct SystemReminderDelivery: ReminderDelivery {
    public init() {}

    static let identifier = "xdict.review.due"

    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    public func isAuthorized() async -> Bool {
        guard hasBundle else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    public func requestAuthorization() async -> Bool {
        guard hasBundle else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func schedule(_ reminder: ReviewReminderPlan.Reminder) async {
        guard hasBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Review due")
        content.body = reminder.due > 0
            ? String(localized: "\(reminder.due) cards are due.")
            : String(localized: "A card is due for review.")
        content.sound = .default
        let interval = max(1, reminder.fireAt.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: Self.identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        try? await center.add(request)
    }

    public func cancel() async {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}

/// **The reader's reminders** (plan §5.4): the switch in Settings ▸ Learning, the system's permission, and the one pending
/// reminder planned from the review summary. The core decides what is due; this only asks the system to say so.
@MainActor
@Observable
public final class ReviewReminders {
    /// The system allows XDict's notifications (false while off, and while not yet asked).
    public private(set) var authorized = false
    /// The reader turned reminders on and the system refused: the row says so rather than the reminder vanishing.
    public private(set) var refused = false

    @ObservationIgnored private let delivery: any ReminderDelivery
    @ObservationIgnored private let preferences: LearningPreferences

    public init(delivery: any ReminderDelivery = SystemReminderDelivery(),
                preferences: LearningPreferences = .shared) {
        self.delivery = delivery
        self.preferences = preferences
    }

    public var isEnabled: Bool { preferences.remindersEnabled }

    /// The reader's switch: on asks the system once; the summary plans the reminder, or removes the one pending.
    public func setEnabled(_ enabled: Bool) async {
        preferences.remindersEnabled = enabled
        guard enabled else {
            await delivery.cancel()
            authorized = false
            refused = false
            return
        }
        authorized = await delivery.requestAuthorization()
        refused = !authorized
    }

    /// Plans the one pending reminder from a summary the core gave, or removes it when nothing is due (or reminders are
    /// off). Called at launch and after every grade, so the reminder follows the queue.
    public func refresh(summary: ReviewSummary?, now: Date = Date()) async {
        guard preferences.remindersEnabled else {
            await delivery.cancel()
            authorized = false
            refused = false
            return
        }
        authorized = await delivery.isAuthorized()
        refused = !authorized
        guard authorized, let summary, let reminder = ReviewReminderPlan.next(summary: summary, now: now) else {
            await delivery.cancel()
            return
        }
        await delivery.schedule(reminder)
    }
}
