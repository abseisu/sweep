// LedgerStats.swift
// Ledger
//
// Tracks user streaks and session stats for the lock screen.
// All data stored in UserDefaults — no API calls, no cost.

import Foundation

final class LedgerStats {

    static let shared = LedgerStats()
    private init() { load() }

    // MARK: - Storage Keys

    private let streakKey = "ledger_streak_count"
    private let lastClearedKey = "ledger_last_cleared_date"
    private let totalClearedKey = "ledger_total_cleared_days"
    private let totalRepliesKey = "ledger_total_replies_sent"
    private let lastSessionRepliesKey = "ledger_last_session_replies"
    private let lastSessionContactsKey = "ledger_last_session_contacts"
    private let longestStreakKey = "ledger_longest_streak"

    // MARK: - State

    /// Current consecutive days cleared
    private(set) var currentStreak: Int = 0
    /// Longest ever streak
    private(set) var longestStreak: Int = 0
    /// Total days the user has cleared their ledger
    private(set) var totalClearedDays: Int = 0
    /// Total replies sent across all sessions
    private(set) var totalReplies: Int = 0
    /// Replies sent in the last session
    private(set) var lastSessionReplies: Int = 0
    /// Names of people replied to in the last session
    private(set) var lastSessionContacts: [String] = []
    /// The date string of the last cleared day
    private(set) var lastClearedDate: String = ""

    // MARK: - Today's Date

    private var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var yesterdayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
    }

    // MARK: - Record a Cleared Session

    /// Call this when the user clears their ledger (all items gone).
    /// Records the session stats and updates the streak.
    func recordClearedSession(repliesSent: Int, contactNames: [String]) {
        let today = todayString

        // Don't double-count the same day
        guard lastClearedDate != today else {
            // Update session stats even if already counted today
            lastSessionReplies = repliesSent
            lastSessionContacts = contactNames
            save()
            return
        }

        // Update streak
        if lastClearedDate == yesterdayString {
            // Consecutive day — extend streak
            currentStreak += 1
        } else if lastClearedDate.isEmpty {
            // First ever session
            currentStreak = 1
        } else {
            // Streak broken — restart
            currentStreak = 1
        }

        if currentStreak > longestStreak {
            longestStreak = currentStreak
        }

        lastClearedDate = today
        totalClearedDays += 1
        totalReplies += repliesSent
        lastSessionReplies = repliesSent
        lastSessionContacts = contactNames

        save()
        print("📊 LedgerStats: streak=\(currentStreak), total days=\(totalClearedDays), total replies=\(totalReplies)")
    }

    /// Record a single reply sent (call from DraftEditorView on send).
    /// This keeps totalReplies accurate even across sessions.
    func recordReply() {
        totalReplies += 1
        UserDefaults.standard.set(totalReplies, forKey: totalRepliesKey)
    }

    // MARK: - Streak Dots (last 7 days)

    /// Returns an array of 7 bools for the last 7 days (index 0 = 6 days ago, index 6 = today).
    /// true = user cleared their ledger that day.
    var weekDots: [Bool] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"

        // We only know consecutive days from the streak, so reconstruct
        // If currentStreak >= 7, all dots are filled
        // Otherwise, fill from today backward
        let cal = Calendar.current
        var dots: [Bool] = []

        for daysAgo in stride(from: 6, through: 0, by: -1) {
            if currentStreak > daysAgo {
                dots.append(true)
            } else if daysAgo == 0 && lastClearedDate == todayString {
                dots.append(true)
            } else {
                dots.append(false)
            }
        }

        return dots
    }

    /// Day labels for the 7 streak dots (Mon, Tue, etc.)
    var weekDayLabels: [String] {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return (0..<7).map { daysAgo in
            let date = cal.date(byAdding: .day, value: -(6 - daysAgo), to: Date()) ?? Date()
            return String(formatter.string(from: date).prefix(1))
        }
    }

    // MARK: - Lock Screen Message

    /// Returns a personal stat message to show on the lock screen instead of (or mixed with) quotes.
    /// Returns nil if there's not enough data yet.
    func personalMessage() -> String? {
        // Need at least one cleared session to say something meaningful
        guard totalClearedDays > 0 else { return nil }

        // Build a pool of messages and pick one based on the day
        var pool: [String] = []

        // Streak messages
        if currentStreak >= 30 {
            pool.append("30-day streak. You're building something rare.")
        } else if currentStreak >= 14 {
            pool.append("\(currentStreak) days in a row. This is becoming second nature.")
        } else if currentStreak >= 7 {
            pool.append("A full week. \(currentStreak) days without missing a beat.")
        } else if currentStreak >= 3 {
            pool.append("\(currentStreak) days running. The habit is forming.")
        }

        // Reply count messages
        if totalReplies >= 100 {
            pool.append("You've sent \(totalReplies) replies through Ledger. That's \(totalReplies) people who heard back.")
        } else if totalReplies >= 50 {
            pool.append("\(totalReplies) replies sent. You're the person who writes back.")
        } else if totalReplies >= 20 {
            pool.append("\(totalReplies) replies and counting.")
        } else if totalReplies >= 5 {
            pool.append("You've sent \(totalReplies) replies so far. Every one mattered to someone.")
        }

        // Last session messages
        if lastSessionReplies > 0 {
            if lastSessionContacts.count == 1 {
                pool.append("You replied to \(lastSessionContacts[0]) yesterday.")
            } else if lastSessionContacts.count == 2 {
                pool.append("Last session: you wrote back to \(lastSessionContacts[0]) and \(lastSessionContacts[1]).")
            } else if lastSessionContacts.count > 2 {
                pool.append("You replied to \(lastSessionReplies) people last time. They appreciated it.")
            }
        }

        // Total days messages
        if totalClearedDays >= 30 {
            pool.append("You've cleared your ledger \(totalClearedDays) times. That's a practice.")
        } else if totalClearedDays >= 10 {
            pool.append("\(totalClearedDays) sessions completed. Your correspondence game is strong.")
        }

        // Longest streak brag
        if longestStreak >= 7 && currentStreak < longestStreak {
            pool.append("Your best streak was \(longestStreak) days. Let's beat it.")
        }

        guard !pool.isEmpty else { return nil }

        // Pick one deterministically based on the day (so it doesn't change on refresh)
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return pool[dayOfYear % pool.count]
    }

    // MARK: - Persistence

    private func save() {
        let ud = UserDefaults.standard
        ud.set(currentStreak, forKey: streakKey)
        ud.set(longestStreak, forKey: longestStreakKey)
        ud.set(lastClearedDate, forKey: lastClearedKey)
        ud.set(totalClearedDays, forKey: totalClearedKey)
        ud.set(totalReplies, forKey: totalRepliesKey)
        ud.set(lastSessionReplies, forKey: lastSessionRepliesKey)
        ud.set(lastSessionContacts, forKey: lastSessionContactsKey)
    }

    private func load() {
        let ud = UserDefaults.standard
        currentStreak = ud.integer(forKey: streakKey)
        longestStreak = ud.integer(forKey: longestStreakKey)
        lastClearedDate = ud.string(forKey: lastClearedKey) ?? ""
        totalClearedDays = ud.integer(forKey: totalClearedKey)
        totalReplies = ud.integer(forKey: totalRepliesKey)
        lastSessionReplies = ud.integer(forKey: lastSessionRepliesKey)
        lastSessionContacts = (ud.array(forKey: lastSessionContactsKey) as? [String]) ?? []

        // Check if streak is still valid (yesterday or today)
        if !lastClearedDate.isEmpty && lastClearedDate != todayString && lastClearedDate != yesterdayString {
            // Streak is broken
            currentStreak = 0
            save()
        }
    }

    /// Reset everything
    func reset() {
        currentStreak = 0
        longestStreak = 0
        totalClearedDays = 0
        totalReplies = 0
        lastSessionReplies = 0
        lastSessionContacts = []
        lastClearedDate = ""
        save()
    }
}
