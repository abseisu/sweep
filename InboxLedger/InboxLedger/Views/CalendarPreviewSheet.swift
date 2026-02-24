// CalendarPreviewSheet.swift
// Ledger
//
// A compact calendar sheet that shows relevant days with events
// and AI-generated availability commentary.
// Triggered when an email mentions scheduling.

import SwiftUI
import EventKit

struct CalendarPreviewSheet: View {
    let emailBody: String
    let emailDate: Date  // When the email was sent — relative words resolve from this
    @Environment(\.dismiss) private var dismiss

    @State private var relevantDays: [CalendarDay] = []

    var body: some View {
        NavigationStack {
            ZStack {
                IL.paper.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        // AI availability summary
                        if let summary = availabilitySummary {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 11))
                                        .foregroundColor(IL.accent)
                                    Text("Availability insight")
                                        .font(IL.serif(11)).italic()
                                        .foregroundColor(IL.inkFaint)
                                }
                                Text(summary)
                                    .font(IL.serif(14))
                                    .foregroundColor(IL.ink)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(IL.inkWhisper)
                            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
                        }

                        // Day-by-day view
                        ForEach(relevantDays) { day in
                            dayCard(day)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Your calendar")
                        .font(IL.serif(16)).italic().foregroundColor(IL.inkLight)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("Done").font(IL.serif(14)).foregroundColor(IL.ink)
                    }
                }
            }
            .onAppear { loadRelevantDays() }
        }
    }

    // MARK: - Day Card

    private func dayCard(_ day: CalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Day header
            HStack {
                Text(day.label)
                    .font(IL.serif(15, weight: .medium))
                    .foregroundColor(IL.ink)
                Spacer()
                Text(day.dateString)
                    .font(IL.serif(12))
                    .foregroundColor(IL.inkFaint)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            Rectangle().fill(IL.rule).frame(height: 0.5).padding(.horizontal, 14)

            if day.events.isEmpty {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.30, green: 0.60, blue: 0.35))
                        .frame(width: 6, height: 6)
                    Text("No events — fully available")
                        .font(IL.serif(13)).italic()
                        .foregroundColor(Color(red: 0.30, green: 0.60, blue: 0.35))
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(day.events.enumerated()), id: \.offset) { idx, event in
                        if idx > 0 {
                            Rectangle().fill(IL.rule).frame(height: 0.5).padding(.leading, 78)
                        }
                        eventRow(event)
                    }

                    // Show free gaps
                    if !day.freeSlots.isEmpty {
                        Rectangle().fill(IL.rule).frame(height: 0.5).padding(.horizontal, 14)
                        ForEach(Array(day.freeSlots.enumerated()), id: \.offset) { _, slot in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(red: 0.30, green: 0.60, blue: 0.35))
                                    .frame(width: 6, height: 6)
                                Text(slot)
                                    .font(IL.serif(12)).italic()
                                    .foregroundColor(Color(red: 0.30, green: 0.60, blue: 0.35))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                    }
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: IL.radius))
        .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.rule, lineWidth: 0.5))
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Time column
            Text(event.timeRange)
                .font(IL.serif(12))
                .foregroundColor(IL.inkFaint)
                .frame(width: 64, alignment: .leading)

            // Event details
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(IL.serif(13, weight: .medium))
                    .foregroundColor(IL.ink)
                    .lineLimit(2)
                if let location = event.location {
                    Text(location)
                        .font(IL.serif(11))
                        .foregroundColor(IL.inkFaint)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Data Loading

    private func loadRelevantDays() {
        guard CalendarManager.shared.isActive else { return }

        let cal = Calendar.current
        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mma"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, MMM d"

        // Detect which days the email references
        let daysToShow = detectRelevantDays(from: emailBody)

        relevantDays = daysToShow.map { dayOffset in
            let dayDate = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
            let dayEnd = dayDate.addingTimeInterval(86400)
            let fetchStart = dayOffset == 0 ? now : dayDate
            let ekEvents = CalendarManager.shared.events(from: fetchStart, to: dayEnd)

            let label: String
            switch dayOffset {
            case 0: label = "Today"
            case 1: label = "Tomorrow"
            default: label = dayFormatter.string(from: dayDate)
            }

            let events = ekEvents.compactMap { event -> CalendarEvent? in
                guard !event.isAllDay else { return nil }
                let startStr = timeFormatter.string(from: event.startDate).lowercased()
                let endStr = timeFormatter.string(from: event.endDate).lowercased()
                return CalendarEvent(
                    title: event.title,
                    timeRange: "\(startStr)–\(endStr)",
                    location: event.location,
                    startDate: event.startDate,
                    endDate: event.endDate
                )
            }

            // Calculate free slots (gaps > 30 min during 8am-8pm)
            let freeSlots = calculateFreeSlots(events: events, dayDate: dayDate, isToday: dayOffset == 0)

            return CalendarDay(
                label: label,
                dateString: dayFormatter.string(from: dayDate),
                events: events,
                freeSlots: freeSlots,
                date: dayDate
            )
        }
    }

    /// Detect which days the email is talking about (returns offsets from TODAY).
    /// Relative words ("tomorrow", "this week") are resolved from the email's send date,
    /// then converted to offsets from the current date.
    private func detectRelevantDays(from body: String) -> [Int] {
        let lower = body.lowercased()
        var targetDates: Set<Date> = [] // Absolute dates the email is referring to
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let emailDay = cal.startOfDay(for: emailDate)

        // 1. Parse explicit dates: "Feb 18", "February 26th", "2/18", "March 3"
        //    These are absolute — don't need email date context
        let parsedDates = parseDatesFromText(body)
        for date in parsedDates {
            targetDates.insert(cal.startOfDay(for: date))
        }

        // 2. Relative words — resolve from email's send date, not today
        if lower.contains("tomorrow") {
            if let d = cal.date(byAdding: .day, value: 1, to: emailDay) {
                targetDates.insert(d)
            }
        }
        if lower.contains("today") || lower.contains("tonight") || lower.contains("this evening") {
            targetDates.insert(emailDay)
        }
        if lower.contains("yesterday") {
            if let d = cal.date(byAdding: .day, value: -1, to: emailDay) {
                targetDates.insert(d)
            }
        }

        // 3. Day-of-week names — resolve to the next occurrence from email date
        let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let emailWeekday = cal.component(.weekday, from: emailDate) - 1 // 0=Sun

        for (index, name) in dayNames.enumerated() {
            if lower.contains(name) || lower.contains(String(name.prefix(3))) {
                var offset = index - emailWeekday
                if offset <= 0 { offset += 7 }
                if let d = cal.date(byAdding: .day, value: offset, to: emailDay) {
                    targetDates.insert(cal.startOfDay(for: d))
                }
            }
        }

        // 4. "Next week" / "this week" — relative to email date
        if lower.contains("next week") {
            let emailWeekdayNum = cal.component(.weekday, from: emailDate)
            let mondayOffset = (9 - emailWeekdayNum) % 7
            for i in 0..<5 {
                if let d = cal.date(byAdding: .day, value: mondayOffset + i, to: emailDay) {
                    targetDates.insert(cal.startOfDay(for: d))
                }
            }
        }
        if lower.contains("this week") {
            let emailWeekdayNum = cal.component(.weekday, from: emailDate)
            for i in 0..<(7 - emailWeekdayNum) {
                if let d = cal.date(byAdding: .day, value: i, to: emailDay) {
                    targetDates.insert(cal.startOfDay(for: d))
                }
            }
        }

        // Convert absolute dates to offsets from today, keep only future/today
        var offsets: Set<Int> = []
        for date in targetDates {
            let offset = cal.dateComponents([.day], from: today, to: date).day ?? 0
            if offset >= 0 && offset <= 30 { offsets.insert(offset) }
        }

        // Default: if nothing found, show today + tomorrow + day after
        if offsets.isEmpty {
            offsets = [0, 1, 2]
        }

        return offsets.sorted().prefix(5).map { $0 }
    }

    /// Parse explicit dates from email text: "Feb 18", "February 26th", "2/18", "March 3rd"
    private func parseDatesFromText(_ text: String) -> [Date] {
        var results: [Date] = []
        let cal = Calendar.current
        let now = Date()
        let currentYear = cal.component(.year, from: now)

        // Strategy 1: Use NSDataDetector — catches most date formats
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, range: range)
            for match in matches {
                if let date = match.date {
                    // If the detected date is in the past, try next year
                    var target = date
                    if cal.startOfDay(for: target) < cal.startOfDay(for: now) {
                        if let nextYear = cal.date(bySetting: .year, value: currentYear + 1, of: target) {
                            target = nextYear
                        }
                    }
                    results.append(target)
                }
            }
        }

        // Strategy 2: Manual regex for patterns NSDataDetector might miss
        // "Feb 18", "Feb. 18", "February 26th"
        let monthPattern = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?"
        if let regex = try? NSRegularExpression(pattern: monthPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if match.numberOfRanges >= 3,
                   let monthRange = Range(match.range(at: 1), in: text),
                   let dayRange = Range(match.range(at: 2), in: text),
                   let day = Int(text[dayRange]) {
                    let monthStr = String(text[monthRange]).lowercased().prefix(3)
                    let months = ["jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
                                  "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12]
                    if let month = months[String(monthStr)] {
                        var comps = DateComponents()
                        comps.year = currentYear
                        comps.month = month
                        comps.day = day
                        if let date = cal.date(from: comps) {
                            var target = date
                            if cal.startOfDay(for: target) < cal.startOfDay(for: now) {
                                comps.year = currentYear + 1
                                target = cal.date(from: comps) ?? target
                            }
                            // Avoid duplicates
                            let targetDay = cal.startOfDay(for: target)
                            if !results.contains(where: { cal.startOfDay(for: $0) == targetDay }) {
                                results.append(target)
                            }
                        }
                    }
                }
            }
        }

        return results
    }

    /// Find free slots > 30min between 8am and 8pm
    private func calculateFreeSlots(events: [CalendarEvent], dayDate: Date, isToday: Bool) -> [String] {
        let cal = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mma"

        var dayStart = cal.date(bySettingHour: 8, minute: 0, second: 0, of: dayDate)!
        let dayEnd = cal.date(bySettingHour: 20, minute: 0, second: 0, of: dayDate)!

        if isToday && Date() > dayStart {
            // Round up to next 30 min
            let now = Date()
            let mins = cal.component(.minute, from: now)
            let roundedMins = mins < 30 ? 30 : 60
            dayStart = cal.date(bySettingHour: cal.component(.hour, from: now) + (roundedMins == 60 ? 1 : 0),
                                minute: roundedMins == 60 ? 0 : 30, second: 0, of: dayDate) ?? now
        }

        guard dayStart < dayEnd else { return [] }

        let sorted = events.sorted { $0.startDate < $1.startDate }
        var slots: [String] = []
        var cursor = dayStart

        for event in sorted {
            if event.startDate > cursor {
                let gap = event.startDate.timeIntervalSince(cursor)
                if gap >= 1800 { // 30+ minutes
                    let start = timeFormatter.string(from: cursor).lowercased()
                    let end = timeFormatter.string(from: event.startDate).lowercased()
                    let hours = Int(gap / 3600)
                    let mins = Int((gap.truncatingRemainder(dividingBy: 3600)) / 60)
                    let duration = hours > 0 ? "\(hours)h\(mins > 0 ? " \(mins)m" : "")" : "\(mins)m"
                    slots.append("Free \(start)–\(end) (\(duration))")
                }
            }
            if event.endDate > cursor { cursor = event.endDate }
        }

        // Final gap
        if cursor < dayEnd {
            let gap = dayEnd.timeIntervalSince(cursor)
            if gap >= 1800 {
                let start = timeFormatter.string(from: cursor).lowercased()
                let hours = Int(gap / 3600)
                let mins = Int((gap.truncatingRemainder(dividingBy: 3600)) / 60)
                let duration = hours > 0 ? "\(hours)h\(mins > 0 ? " \(mins)m" : "")" : "\(mins)m"
                slots.append("Free \(start)–8:00pm (\(duration))")
            }
        }

        return slots
    }

    // MARK: - AI Summary

    /// Generates a quick natural-language availability summary based on the email context
    private var availabilitySummary: String? {
        guard !relevantDays.isEmpty else { return nil }

        var parts: [String] = []

        for day in relevantDays {
            if day.events.isEmpty {
                parts.append("\(day.label) is wide open.")
            } else if day.freeSlots.isEmpty {
                parts.append("\(day.label) is packed — no gaps longer than 30 minutes.")
            } else {
                let bestSlot = day.freeSlots.first ?? ""
                parts.append("\(day.label) has \(day.events.count) event\(day.events.count == 1 ? "" : "s"), but you're \(bestSlot.lowercased()).")
            }
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Models

struct CalendarDay: Identifiable {
    let id = UUID()
    let label: String       // "Today", "Tomorrow", "Wed, Feb 12"
    let dateString: String   // "Wed, Feb 12"
    let events: [CalendarEvent]
    let freeSlots: [String]  // "Free 2:00pm–4:00pm (2h)"
    let date: Date
}

struct CalendarEvent {
    let title: String
    let timeRange: String    // "10:00am–11:00am"
    let location: String?
    let startDate: Date
    let endDate: Date
}

// MARK: - Calendar Chip (reusable)

/// A small tappable chip that appears on email cards and draft editor
/// when the email mentions scheduling. Tap to open CalendarPreviewSheet.
struct CalendarChip: View {
    let emailBody: String
    let emailDate: Date  // When the email was sent
    @State private var showCalendar = false

    /// Returns true if this email mentions time/scheduling and calendar is active
    static func shouldShow(for emailBody: String) -> Bool {
        guard CalendarManager.shared.isActive else { return false }
        let lower = emailBody.lowercased()

        // Check for scheduling words
        let indicators = [
            "meet", "meeting", "call", "lunch", "dinner", "coffee", "drinks",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "tomorrow", "next week", "this week", "schedule", "available", "free time",
            "slot", "catch up", "get together", "sync up", "check in",
            "can we", "are you free", "would you be available"
        ]
        if indicators.contains(where: { lower.contains($0) }) { return true }

        // Check for explicit dates (Feb 18, March 3rd, 2/18, etc.)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(emailBody.startIndex..., in: emailBody)
            if !detector.matches(in: emailBody, range: range).isEmpty { return true }
        }

        // Check month names followed by numbers
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        for month in months {
            if lower.contains(month) {
                // Check if followed by a number nearby
                if let regex = try? NSRegularExpression(pattern: "\(month)\\w*\\.?\\s+\\d{1,2}", options: .caseInsensitive) {
                    let range = NSRange(lower.startIndex..., in: lower)
                    if !regex.matches(in: lower, range: range).isEmpty { return true }
                }
            }
        }

        return false
    }

    var body: some View {
        Button { showCalendar = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .medium))
                Text(chipText)
                    .font(IL.serif(11))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundColor(IL.ink.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(IL.inkWhisper)
            .clipShape(RoundedRectangle(cornerRadius: IL.radius))
            .overlay(RoundedRectangle(cornerRadius: IL.radius).stroke(IL.rule, lineWidth: 0.5))
        }
        .sheet(isPresented: $showCalendar) {
            CalendarPreviewSheet(emailBody: emailBody, emailDate: emailDate)
        }
    }

    /// Quick one-line summary for the chip label
    private var chipText: String {
        guard CalendarManager.shared.isActive else { return "Calendar" }

        let cal = Calendar.current
        let now = Date()

        // Find the primary date the email references
        let checkDate = primaryDateFromEmail(emailBody) ?? now

        let dayStart = cal.startOfDay(for: checkDate)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let fetchStart = cal.isDateInToday(checkDate) ? now : dayStart
        let events = CalendarManager.shared.events(from: fetchStart, to: dayEnd)
            .filter { !$0.isAllDay }

        // Build a readable day label
        let dayLabel: String
        if cal.isDateInToday(checkDate) {
            dayLabel = "today"
        } else if cal.isDateInTomorrow(checkDate) {
            dayLabel = "tomorrow"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            dayLabel = "on \(fmt.string(from: checkDate))"
        }

        if events.isEmpty {
            return "You're free \(dayLabel)"
        } else {
            return "\(events.count) event\(events.count == 1 ? "" : "s") \(dayLabel) — tap to check"
        }
    }

    /// Extract the most prominent date from email text.
    /// Relative words resolve from the email's send date, not today.
    private func primaryDateFromEmail(_ text: String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let lower = text.lowercased()
        let currentYear = cal.component(.year, from: now)
        let emailDay = cal.startOfDay(for: emailDate)

        // 1. Try NSDataDetector for explicit dates (Feb 18, 2/18, etc.)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, range: range)
            for match in matches {
                if let date = match.date {
                    var target = date
                    if cal.startOfDay(for: target) < cal.startOfDay(for: now) {
                        if let nextYear = cal.date(bySetting: .year, value: currentYear + 1, of: target) {
                            target = nextYear
                        }
                    }
                    return target
                }
            }
        }

        // 2. Relative words — resolve from email send date
        if lower.contains("tomorrow") {
            return cal.date(byAdding: .day, value: 1, to: emailDay)
        }
        if lower.contains("today") || lower.contains("tonight") {
            return emailDay
        }

        // 3. Day names — next occurrence from email date
        let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let emailWeekday = cal.component(.weekday, from: emailDate) - 1
        for (index, name) in dayNames.enumerated() {
            if lower.contains(name) {
                var offset = index - emailWeekday
                if offset <= 0 { offset += 7 }
                return cal.date(byAdding: .day, value: offset, to: emailDay)
            }
        }

        return nil
    }
}
