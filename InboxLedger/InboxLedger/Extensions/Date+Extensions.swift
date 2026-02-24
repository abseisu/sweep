// Date+Extensions.swift
// Inbox Ledger

import Foundation

extension Date {
    /// Returns the date exactly 24 hours before now.
    static var twentyFourHoursAgo: Date {
        Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
    }

    /// Returns the date to scan from — at LEAST 24 hours, but goes back further
    /// to the last ledger window (up to 72h) so nothing is missed between sessions.
    static var sinceLastWindow: Date {
        let minimum = twentyFourHoursAgo  // Always at least 24h
        let maxLookback = Calendar.current.date(byAdding: .hour, value: -72, to: Date())!

        if let lastTimestamp = UserDefaults.standard.object(forKey: "ledger_last_window_timestamp") as? Double {
            let lastDate = Date(timeIntervalSince1970: lastTimestamp)
            // Go back to last window, but no further than 72h and no less than 24h
            let candidate = max(lastDate, maxLookback)
            return min(candidate, minimum)  // min = further back in time = more emails
        }
        // No record yet — default to 24h
        return minimum
    }
}
