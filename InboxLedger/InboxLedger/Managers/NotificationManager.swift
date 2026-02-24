// NotificationManager.swift
// Inbox Ledger
//
// NOTIFICATION PROTOCOL:
// 1. NEVER send notifications while user is in the app (enforced by AppDelegate + foreground cancellation)
// 2. When the ledger opens, send ONE notification with "Open Now" / "Postpone 1h" actions
// 3. Every 5 minutes until ledger is cleared: sleek, quirky, escalating reminders
//    - With time warnings at 30m, 20m, 10m, 5m remaining
//    - Gets increasingly sassy and urgent
// 4. When user clears ledger and exits the app: ONE congratulatory notification, never repeated

import Foundation
import UserNotifications

final class NotificationManager {

    static let shared = NotificationManager()
    private init() {}

    // MARK: - Identifiers

    private let mainID = "com.inboxledger.window-open"
    private let nagPrefix = "com.inboxledger.nag-"
    private let clearedID = "com.inboxledger.cleared"
    private let postponedID = "com.inboxledger.postponed"

    /// 5-minute intervals over 1 hour = 11 nags (at 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55 min)
    private let nagIntervalMinutes = 5
    private let nagCount = 11

    // MARK: - Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, error in
            if let error = error {
                print("⚠️ Notification permission error: \(error.localizedDescription)")
            }
            print(granted ? "✅ Notifications enabled" : "⚠️ Notifications denied")
        }
    }

    // MARK: - Register Notification Actions

    func registerCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_LEDGER",
            title: "Open Now",
            options: [.foreground]
        )
        let postponeAction = UNNotificationAction(
            identifier: "POSTPONE_1H",
            title: "Postpone 1h",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "LEDGER_WINDOW",
            actions: [openAction, postponeAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Time to sweep"
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Schedule Daily Window Notification + Nags

    /// Schedules the main daily notification plus 5-minute follow-up nags.
    /// Called on app launch and whenever the user changes their schedule.
    func scheduleNightlyReminder(hour: Int, minute: Int) {
        cancelAll()

        let center = UNUserNotificationCenter.current()

        // 1. Main window-open notification
        let mainContent = UNMutableNotificationContent()
        mainContent.title = "Time to Clear the Ledger"
        mainContent.body = "You have messages waiting. Open Sweep — your hour starts now."
        mainContent.sound = SoundManager.notificationSound
        mainContent.badge = 1
        mainContent.interruptionLevel = .timeSensitive
        mainContent.categoryIdentifier = "LEDGER_WINDOW"

        var mainDate = DateComponents()
        mainDate.hour = hour
        mainDate.minute = minute

        let mainTrigger = UNCalendarNotificationTrigger(dateMatching: mainDate, repeats: true)
        let mainRequest = UNNotificationRequest(identifier: mainID, content: mainContent, trigger: mainTrigger)

        center.add(mainRequest) { error in
            if let error = error {
                print("❌ Failed to schedule main notification: \(error.localizedDescription)")
            } else {
                print("✅ Main reminder set for \(hour):\(String(format: "%02d", minute))")
            }
        }

        // 2. Follow-up nags every 5 minutes
        for i in 1...nagCount {
            let minutesAfterOpen = i * nagIntervalMinutes
            let minutesRemaining = 60 - minutesAfterOpen

            let nagMinuteRaw = minute + minutesAfterOpen
            let adjustedHour = (hour + nagMinuteRaw / 60) % 24
            let adjustedMinute = nagMinuteRaw % 60

            let nagContent = UNMutableNotificationContent()
            nagContent.title = "Ledger"
            nagContent.body = nagMessage(index: i, minutesRemaining: minutesRemaining)
            nagContent.sound = SoundManager.notificationSound
            nagContent.badge = NSNumber(value: i + 1)
            nagContent.interruptionLevel = .timeSensitive

            var nagDate = DateComponents()
            nagDate.hour = adjustedHour
            nagDate.minute = adjustedMinute

            let nagTrigger = UNCalendarNotificationTrigger(dateMatching: nagDate, repeats: true)
            let nagRequest = UNNotificationRequest(
                identifier: "\(nagPrefix)\(i)",
                content: nagContent,
                trigger: nagTrigger
            )
            center.add(nagRequest)
        }

        print("✅ Scheduled \(nagCount) nag notifications every \(nagIntervalMinutes)min")
    }

    // MARK: - Nag Message Generator

    /// Generates sleek, quirky, escalating nag messages.
    /// Time-specific warnings at 30m, 20m, 10m, 5m. Otherwise creative rotation.
    private func nagMessage(index: Int, minutesRemaining: Int) -> String {
        // Time-specific warnings always take priority
        switch minutesRemaining {
        case 30:
            return "Halfway gone. 30 minutes left."
        case 20:
            return "20 minutes. The clock doesn't care about your excuses."
        case 10:
            return "10 minutes. This is the part where you open the app."
        case 5:
            return "5 minutes. Last call."
        default:
            break
        }

        // Early (5-15 min in): gentle, witty nudges
        let earlyMessages = [
            "Someone out there is waiting to hear from you.",
            "Your inbox called. It misses you.",
            "A few taps. A few replies. That's the whole thing.",
        ]

        // Mid (20-35 min in): escalating sass
        let midMessages = [
            "Still here. Still waiting. Still judging.",
            "The sweep is patient. Your window isn't.",
            "Future you will thank present you. Open Sweep.",
            "You're not too busy. You're just avoiding it.",
        ]

        // Late (40-55 min in): full personality
        let lateMessages = [
            "This is getting embarrassing for both of us.",
            "Notification #\(index + 1). You know how to make it stop.",
            "We can do this all night. Or you can just open the app.",
            "Your ledger is starting to take this personally.",
        ]

        if index <= 3 {
            return earlyMessages[(index - 1) % earlyMessages.count]
        } else if index <= 7 {
            return midMessages[(index - 4) % midMessages.count]
        } else {
            return lateMessages[(index - 8) % lateMessages.count]
        }
    }

    // MARK: - Re-schedule Nags (user backgrounds mid-window)

    /// Called when user leaves the app while the window is open and ledger isn't cleared.
    /// Schedules nags at 5-minute intervals from now until the window closes.
    func scheduleRemainingNags(startingAt start: Date, until end: Date) {
        cancelAllNags()

        let center = UNUserNotificationCenter.current()
        let totalSeconds = end.timeIntervalSince(start)
        let totalNags = min(nagCount, Int(totalSeconds / Double(nagIntervalMinutes * 60)))
        guard totalNags > 0 else { return }

        for i in 0..<totalNags {
            let fireDate = start.addingTimeInterval(Double(i * nagIntervalMinutes * 60))
            guard fireDate < end else { break }

            let minutesRemaining = Int(end.timeIntervalSince(fireDate) / 60)

            let content = UNMutableNotificationContent()
            content.title = "Sweep"
            content.body = nagMessage(index: i + 1, minutesRemaining: minutesRemaining)
            content.sound = SoundManager.notificationSound
            content.badge = NSNumber(value: i + 2)
            content.interruptionLevel = .timeSensitive

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(nagPrefix)\(i + 1)",
                content: content,
                trigger: trigger
            )
            center.add(request)
        }

        print("✅ Re-scheduled \(totalNags) nags until window closes")
    }

    // MARK: - Cleared Notification

    /// Send ONE congratulatory notification. Called when user backgrounds after clearing ledger.
    /// Fires 2 seconds after backgrounding so it appears on the lock screen.
    func sendClearedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Swept Away ✓"
        content.body = "All caught up. Well done!"
        content.sound = SoundManager.notificationSound
        content.badge = 0

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(
            identifier: clearedID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
        print("✅ Scheduled 'ledger cleared' notification")
    }

    // MARK: - Postponed Reminder

    /// Schedule a one-time reminder at the user's chosen postponed time (today only).
    /// Also pre-schedules nags starting 5 minutes after the new window time.
    func schedulePostponedReminder(hour: Int, minute: Int) {
        // Cancel existing main + nags (they're set for the old time)
        cancelAllNags()
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [mainID, postponedID]
        )

        let content = UNMutableNotificationContent()
        content.title = "Time to Sweep"
        content.body = "Your window is open. One hour — let's go."
        content.sound = SoundManager.notificationSound
        content.badge = 1
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = "LEDGER_WINDOW"

        let cal = Calendar.current
        var fireComponents = cal.dateComponents([.year, .month, .day], from: Date())
        fireComponents.hour = hour
        fireComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: fireComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: postponedID,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)

        // Also pre-schedule nags starting 5 minutes after the new window time
        if let fireDate = cal.date(from: fireComponents) {
            let windowEnd = fireDate.addingTimeInterval(3600)
            let nagStart = fireDate.addingTimeInterval(Double(nagIntervalMinutes * 60))
            scheduleRemainingNags(startingAt: nagStart, until: windowEnd)
        }

        print("✅ Rescheduled window for \(hour):\(String(format: "%02d", minute))")
    }

    // MARK: - Cancel

    /// Cancel all nag notifications + clear delivered + reset badge.
    /// Called when user enters the app (foreground).
    func cancelAllNags() {
        let nagIDs = (1...nagCount).map { "\(nagPrefix)\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: nagIDs)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Cancel everything — main, postponed, nags, cleared.
    /// Called when rescheduling from scratch.
    func cancelAll() {
        var allIDs = [mainID, postponedID, clearedID, conflictID]
        allIDs.append(contentsOf: (1...nagCount).map { "\(nagPrefix)\($0)" })
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: allIDs)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Legacy compatibility
    func cancelReminder() {
        cancelAll()
    }

    // MARK: - Calendar Conflict Notification

    private let conflictID = "com.inboxledger.calendar-conflict"

    /// Sends a notification suggesting an alternate window time due to a calendar conflict.
    /// Fires 30 minutes before the scheduled window so the user has time to adjust.
    func scheduleConflictNotification(suggestion: WindowConflictSuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Ledger"
        content.body = suggestion.message
        content.sound = SoundManager.notificationSound
        content.interruptionLevel = .active

        // Fire 30 minutes before the original window
        let cal = Calendar.current
        var fireComponents = cal.dateComponents([.year, .month, .day], from: Date())
        fireComponents.hour = suggestion.originalHour
        fireComponents.minute = suggestion.originalMinute
        guard let windowTime = cal.date(from: fireComponents) else { return }

        let fireTime = windowTime.addingTimeInterval(-1800) // 30 min before
        guard fireTime > Date() else { return } // Don't schedule in the past

        let fireComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireTime)
        let trigger = UNCalendarNotificationTrigger(dateMatching: fireComps, repeats: false)
        let request = UNNotificationRequest(identifier: conflictID, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if error == nil {
                print("✅ Calendar conflict notification scheduled for 30min before window")
            }
        }
    }

    func cancelConflictNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [conflictID])
    }

    // MARK: - Stack Mode Notifications

    private let batchID = "com.inboxledger.batch-ready"
    private let urgentPrefix = "com.inboxledger.urgent-"

    /// Sends a batch notification: "Your ledger is ready. 8 replies, ~12 minutes."
    func sendBatchNotification(cardCount: Int, mustReplyCount: Int, estimatedMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Your sweep stack is ready"

        // Compose a priority-aware body
        let otherCount = cardCount - mustReplyCount
        if mustReplyCount > 0 && otherCount > 0 {
            content.body = "\(mustReplyCount) need a reply, plus \(otherCount) others. About \(estimatedMinutes) minutes."
        } else if mustReplyCount > 0 {
            content.body = "\(mustReplyCount) messages need a reply. About \(estimatedMinutes) minutes."
        } else {
            content.body = "\(cardCount) messages worth replying to. About \(estimatedMinutes) minutes."
        }

        content.sound = SoundManager.notificationSound
        content.categoryIdentifier = "LEDGER_BATCH"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: batchID, content: content, trigger: trigger)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [batchID])
        UNUserNotificationCenter.current().add(request) { error in
            if error == nil {
                print("📬 Batch notification sent: \(cardCount) cards (\(mustReplyCount) must), ~\(estimatedMinutes) min")
            }
        }
    }

    /// Sends an urgent notification for a single time-sensitive email.
    func sendUrgentNotification(sender: String, subject: String, summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "From \(sender)"
        content.subtitle = subject
        content.body = summary
        content.sound = UNNotificationSound.defaultCritical
        content.categoryIdentifier = "LEDGER_URGENT"
        content.interruptionLevel = .timeSensitive

        let id = "\(urgentPrefix)\(UUID().uuidString.prefix(8))"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if error == nil {
                print("🚨 Urgent notification: \(sender) — \(subject)")
            }
        }
    }

    /// Sends an optional evening reminder for stack mode users who chose one.
    func scheduleEveningReminder(hour: Int, minute: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Your sweep stack is ready"
        content.body = "Clear your replies whenever you're ready."
        content.sound = SoundManager.notificationSound
        content.categoryIdentifier = "LEDGER_BATCH"

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "com.inboxledger.evening-reminder", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if error == nil {
                print("✅ Evening reminder set for \(hour):\(String(format: "%02d", minute))")
            }
        }
    }

    func cancelEveningReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["com.inboxledger.evening-reminder"])
    }

    /// Register categories for stack mode notifications
    func registerStackCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_LEDGER",
            title: "Clear Now",
            options: [.foreground]
        )
        let batchCategory = UNNotificationCategory(
            identifier: "LEDGER_BATCH",
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        let replyAction = UNNotificationAction(
            identifier: "OPEN_URGENT",
            title: "Reply",
            options: [.foreground]
        )
        let urgentCategory = UNNotificationCategory(
            identifier: "LEDGER_URGENT",
            actions: [replyAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([batchCategory, urgentCategory])
    }
}
