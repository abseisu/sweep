// CalendarManager.swift
// Ledger
//
// Multi-source calendar integration:
// - EventKit (iCloud, and any accounts synced to iOS Calendar)
// - Google Calendar API (via existing Gmail OAuth token)
// - Outlook Calendar API (via existing Outlook OAuth token)
//
// All sources are merged and deduplicated into a unified LedgerCalendarEvent model.

import Foundation
import EventKit

// MARK: - Unified Calendar Event

/// A calendar event from any source, used throughout the app.
struct LedgerCalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let source: CalendarSource
    let status: EventStatus

    enum CalendarSource: String {
        case eventKit = "ical"
        case google = "gcal"
        case outlook = "outlook"
    }

    enum EventStatus {
        case confirmed, tentative, canceled
    }

    /// Dedup key: same title + same start time (within 1 minute) = same event
    var dedupKey: String {
        let roundedStart = Int(startDate.timeIntervalSince1970 / 60)
        return "\(title.lowercased().trimmingCharacters(in: .whitespaces))_\(roundedStart)"
    }
}

// MARK: - Calendar Manager

final class CalendarManager {

    static let shared = CalendarManager()
    private init() {}

    private let store = EKEventStore()

    /// App-level toggle
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ledger_calendar_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ledger_calendar_enabled") }
    }

    // MARK: - Status

    var isActive: Bool {
        isEnabled && hasAnyCalendarSource
    }

    var hasAnyCalendarSource: Bool {
        isAuthorized || hasGoogleCalendarAccounts || hasOutlookCalendarAccounts
    }

    var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            return status == .fullAccess || status == .authorized
        } else {
            return status == .authorized
        }
    }

    var hasGoogleCalendarAccounts: Bool {
        UserDefaults.standard.bool(forKey: "ledger_has_gmail_accounts")
    }

    var hasOutlookCalendarAccounts: Bool {
        UserDefaults.standard.bool(forKey: "ledger_has_outlook_accounts")
    }

    /// Call when accounts change so CalendarManager knows what's available
    func updateAccountFlags(hasGmail: Bool, hasOutlook: Bool) {
        UserDefaults.standard.set(hasGmail, forKey: "ledger_has_gmail_accounts")
        UserDefaults.standard.set(hasOutlook, forKey: "ledger_has_outlook_accounts")
    }

    func requestAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            print("⚠️ Calendar access error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Unified Event Fetch (async — merges all sources)

    func allEvents(from start: Date, to end: Date) async -> [LedgerCalendarEvent] {
        guard isActive else { return [] }
        var all: [LedgerCalendarEvent] = []

        if isAuthorized {
            all.append(contentsOf: eventKitEvents(from: start, to: end))
        }
        if hasGoogleCalendarAccounts {
            all.append(contentsOf: await fetchGoogleCalendarEvents(from: start, to: end))
        }
        if hasOutlookCalendarAccounts {
            all.append(contentsOf: await fetchOutlookCalendarEvents(from: start, to: end))
        }

        return deduplicateEvents(all).sorted { $0.startDate < $1.startDate }
    }

    /// Synchronous — EventKit + cached API events. Used by conflict checks and AI injection.
    func events(from start: Date, to end: Date) -> [LedgerCalendarEvent] {
        guard isActive else { return [] }
        var all = eventKitEvents(from: start, to: end)
        let cached = cachedAPIEvents.filter { $0.startDate >= start && $0.startDate <= end }
        all.append(contentsOf: cached)
        return deduplicateEvents(all).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - API Cache

    private var cachedAPIEvents: [LedgerCalendarEvent] = []
    private var lastAPIFetch: Date? = nil

    /// Call on app foreground and after account changes
    func refreshAPICache() async {
        let now = Date()
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        var apiEvents: [LedgerCalendarEvent] = []

        if hasGoogleCalendarAccounts {
            apiEvents.append(contentsOf: await fetchGoogleCalendarEvents(from: now, to: endOfWeek))
        }
        if hasOutlookCalendarAccounts {
            apiEvents.append(contentsOf: await fetchOutlookCalendarEvents(from: now, to: endOfWeek))
        }

        cachedAPIEvents = apiEvents
        lastAPIFetch = now
        print("📅 Calendar API cache refreshed: \(apiEvents.count) events")
    }

    /// Whether cache is stale (older than 15 min)
    var needsCacheRefresh: Bool {
        guard let last = lastAPIFetch else { return true }
        return Date().timeIntervalSince(last) > 900
    }

    // MARK: - EventKit Source

    private func eventKitEvents(from start: Date, to end: Date) -> [LedgerCalendarEvent] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { ek -> LedgerCalendarEvent? in
            guard let s = ek.startDate, let e = ek.endDate else { return nil }
            let status: LedgerCalendarEvent.EventStatus
            switch ek.status {
            case .canceled: status = .canceled
            case .tentative: status = .tentative
            default: status = .confirmed
            }
            return LedgerCalendarEvent(
                id: ek.eventIdentifier ?? UUID().uuidString,
                title: ek.title ?? "Busy",
                startDate: s, endDate: e,
                isAllDay: ek.isAllDay,
                location: ek.location,
                source: .eventKit,
                status: status
            )
        }
    }

    // MARK: - Google Calendar API

    private func fetchGoogleCalendarEvents(from start: Date, to end: Date) async -> [LedgerCalendarEvent] {
        guard let token = getGmailToken() else { return [] }

        let iso = ISO8601DateFormatter()
        let timeMin = iso.string(from: start).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let timeMax = iso.string(from: end).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=\(timeMin)&timeMax=\(timeMax)&singleEvents=true&orderBy=startTime&maxResults=50"

        guard let url = URL(string: urlStr) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [] }

            if http.statusCode == 403 || http.statusCode == 401 {
                print("⚠️ Google Calendar: need calendar scope (HTTP \(http.statusCode))")
                return []
            }
            guard http.statusCode == 200 else {
                print("⚠️ Google Calendar API: HTTP \(http.statusCode)")
                return []
            }

            let decoded = try JSONDecoder().decode(GCalEventList.self, from: data)
            return decoded.items?.compactMap { item -> LedgerCalendarEvent? in
                guard let s = item.startDate, let e = item.endDate else { return nil }
                let status: LedgerCalendarEvent.EventStatus
                switch item.status {
                case "cancelled": status = .canceled
                case "tentative": status = .tentative
                default: status = .confirmed
                }
                return LedgerCalendarEvent(
                    id: "gcal_\(item.id ?? UUID().uuidString)",
                    title: item.summary ?? "Busy",
                    startDate: s, endDate: e,
                    isAllDay: item.start?.date != nil,
                    location: item.location,
                    source: .google,
                    status: status
                )
            } ?? []
        } catch {
            print("⚠️ Google Calendar fetch: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Outlook Calendar API

    private func fetchOutlookCalendarEvents(from start: Date, to end: Date) async -> [LedgerCalendarEvent] {
        guard let token = getOutlookToken() else { return [] }

        let iso = ISO8601DateFormatter()
        let startStr = iso.string(from: start)
        let endStr = iso.string(from: end)
        let urlStr = "https://graph.microsoft.com/v1.0/me/calendarview?startdatetime=\(startStr)&enddatetime=\(endStr)&$top=50&$select=subject,start,end,isAllDay,location,isCancelled,showAs"

        guard let encoded = urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [] }

            if http.statusCode == 403 || http.statusCode == 401 {
                print("⚠️ Outlook Calendar: need Calendars.Read scope (HTTP \(http.statusCode))")
                return []
            }
            guard http.statusCode == 200 else {
                print("⚠️ Outlook Calendar API: HTTP \(http.statusCode)")
                return []
            }

            let decoded = try JSONDecoder().decode(OutlookCalendarResponse.self, from: data)
            return decoded.value?.compactMap { item -> LedgerCalendarEvent? in
                guard let s = item.startDate, let e = item.endDate else { return nil }
                let status: LedgerCalendarEvent.EventStatus
                if item.isCancelled == true { status = .canceled }
                else if item.showAs == "tentative" { status = .tentative }
                else { status = .confirmed }
                return LedgerCalendarEvent(
                    id: "outlook_\(item.id ?? UUID().uuidString)",
                    title: item.subject ?? "Busy",
                    startDate: s, endDate: e,
                    isAllDay: item.isAllDay ?? false,
                    location: item.location?.displayName,
                    source: .outlook,
                    status: status
                )
            } ?? []
        } catch {
            print("⚠️ Outlook Calendar fetch: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Token Access

    private func getGmailToken() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "ledger_accounts"),
              let accounts = try? JSONDecoder().decode([ConnectedAccount].self, from: data) else { return nil }
        guard let account = accounts.first(where: { $0.service == .gmail }) else { return nil }
        // Token loaded from Keychain via ConnectedAccount's custom Codable
        return account.accessToken.isEmpty ? nil : account.accessToken
    }

    private func getOutlookToken() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "ledger_accounts"),
              let accounts = try? JSONDecoder().decode([ConnectedAccount].self, from: data) else { return nil }
        guard let account = accounts.first(where: { $0.service == .outlook }) else { return nil }
        return account.accessToken.isEmpty ? nil : account.accessToken
    }

    // MARK: - Dedup

    private func deduplicateEvents(_ events: [LedgerCalendarEvent]) -> [LedgerCalendarEvent] {
        var seen: Set<String> = []
        var result: [LedgerCalendarEvent] = []
        // Prefer EventKit, then Google, then Outlook
        let prioritized = events.sorted {
            let p0: Int = $0.source == .eventKit ? 0 : ($0.source == .google ? 1 : 2)
            let p1: Int = $1.source == .eventKit ? 0 : ($1.source == .google ? 1 : 2)
            return p0 < p1
        }
        for event in prioritized {
            if event.status == .canceled { continue }
            if seen.contains(event.dedupKey) { continue }
            seen.insert(event.dedupKey)
            result.append(event)
        }
        return result
    }

    // MARK: - Convenience

    func events(duringHour hour: Int, minute: Int, on date: Date = Date()) -> [LedgerCalendarEvent] {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        guard let windowStart = cal.date(from: components) else { return [] }
        let windowEnd = windowStart.addingTimeInterval(3600)
        return events(from: windowStart, to: windowEnd)
    }

    // MARK: - Calendar-Aware Draft Context

    func availabilityContext(for emailBody: String) -> String? {
        guard isActive else { return nil }

        let timeIndicators = [
            "meet", "meeting", "call", "lunch", "dinner", "coffee", "drinks",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "tomorrow", "next week", "this week", "schedule", "available", "free",
            "slot", "time to", "catch up", "get together", "sync", "check in",
            "morning", "afternoon", "evening", "noon",
            "1pm", "2pm", "3pm", "4pm", "5pm", "6pm", "7pm", "8pm", "9pm", "10pm",
            "1:00", "2:00", "3:00", "4:00", "5:00", "6:00", "7:00", "8:00", "9:00"
        ]

        let lowerBody = emailBody.lowercased()
        guard timeIndicators.contains(where: { lowerBody.contains($0) }) else { return nil }

        let cal = Calendar.current
        let now = Date()
        var lines: [String] = ["CALENDAR CONTEXT (use this to suggest times in the reply):"]

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mma"

        for dayOffset in 0...2 {
            guard let dayStart = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) else { continue }
            let dayEnd = dayStart.addingTimeInterval(86400)
            let dayEvents = events(from: max(dayStart, now), to: dayEnd).filter { !$0.isAllDay }

            let dayLabel = dayOffset == 0 ? "Today" : (dayOffset == 1 ? "Tomorrow" : dayFormatter.string(from: dayStart))

            if dayEvents.isEmpty {
                lines.append("- \(dayLabel): No events (fully available)")
            } else {
                let strs = dayEvents.prefix(5).map { e in
                    "\(timeFormatter.string(from: e.startDate).lowercased())-\(timeFormatter.string(from: e.endDate).lowercased()) \(e.title)"
                }
                lines.append("- \(dayLabel): \(strs.joined(separator: ", "))")
            }
        }

        lines.append("- When suggesting times, pick gaps between events. Never double-book.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Smart Window Timing

    func windowConflict(hour: Int, minute: Int) -> WindowConflictSuggestion? {
        guard isActive else { return nil }

        let realConflicts = events(duringHour: hour, minute: minute).filter {
            !$0.isAllDay && $0.status != .canceled && !$0.title.isEmpty
        }
        guard let first = realConflicts.first else { return nil }

        let cal = Calendar.current
        let now = Date()

        let beforeTime = first.startDate.addingTimeInterval(-3600)
        let beforeComps = cal.dateComponents([.hour, .minute], from: beforeTime)

        let last = realConflicts.last ?? first
        let afterComps = cal.dateComponents([.hour, .minute], from: last.endDate)

        let sugH: Int
        let sugM: Int
        if beforeTime > now {
            sugH = beforeComps.hour ?? hour
            sugM = beforeComps.minute ?? 0
        } else {
            sugH = afterComps.hour ?? hour
            sugM = afterComps.minute ?? 0
        }

        if sugH == hour && sugM == minute { return nil }
        if sugH >= 23 || sugH < 6 { return nil }

        return WindowConflictSuggestion(
            conflictEventTitle: first.title,
            conflictStart: first.startDate,
            conflictEnd: last.endDate,
            suggestedHour: sugH, suggestedMinute: sugM,
            originalHour: hour, originalMinute: minute
        )
    }
}

// MARK: - Window Conflict Model

struct WindowConflictSuggestion {
    let conflictEventTitle: String
    let conflictStart: Date
    let conflictEnd: Date
    let suggestedHour: Int
    let suggestedMinute: Int
    let originalHour: Int
    let originalMinute: Int

    var message: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mma"
        let time = fmt.string(from: conflictStart).lowercased()
        return "You have \"\(conflictEventTitle)\" at \(time). Open Ledger at \(formatSuggestedTime) instead?"
    }

    var formatSuggestedTime: String {
        let period = suggestedHour >= 12 ? "pm" : "am"
        let h = suggestedHour > 12 ? suggestedHour - 12 : (suggestedHour == 0 ? 12 : suggestedHour)
        if suggestedMinute == 0 { return "\(h)\(period)" }
        return "\(h):\(String(format: "%02d", suggestedMinute))\(period)"
    }
}

// MARK: - Google Calendar API Models

struct GCalEventList: Decodable {
    let items: [GCalEvent]?
}

struct GCalEvent: Decodable {
    let id: String?
    let summary: String?
    let status: String?
    let location: String?
    let start: GCalTime?
    let end: GCalTime?

    var startDate: Date? { start?.dateTime ?? start?.dateAsDate }
    var endDate: Date? { end?.dateTime ?? end?.dateAsDate }
}

struct GCalTime: Decodable {
    let dateTime: Date?
    let date: String?

    var dateAsDate: Date? {
        guard let date = date else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: date)
    }

    enum CodingKeys: String, CodingKey { case dateTime, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        if let dtString = try c.decodeIfPresent(String.self, forKey: .dateTime) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            dateTime = iso.date(from: dtString) ?? {
                let basic = ISO8601DateFormatter()
                basic.formatOptions = [.withInternetDateTime]
                return basic.date(from: dtString)
            }()
        } else {
            dateTime = nil
        }
    }
}

// MARK: - Outlook Calendar API Models

struct OutlookCalendarResponse: Decodable { let value: [OutlookCalendarEvent]? }

struct OutlookCalendarEvent: Decodable {
    let id: String?
    let subject: String?
    let isAllDay: Bool?
    let isCancelled: Bool?
    let showAs: String?
    let location: OutlookLocation?
    let start: OutlookDateTimeZone?
    let end: OutlookDateTimeZone?

    var startDate: Date? { start?.asDate }
    var endDate: Date? { end?.asDate }
}

struct OutlookLocation: Decodable { let displayName: String? }

struct OutlookDateTimeZone: Decodable {
    let dateTime: String?
    let timeZone: String?

    var asDate: Date? {
        guard let dt = dateTime else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: dt) { return d }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        fmt.timeZone = TimeZone(identifier: timeZone ?? "UTC")
        return fmt.date(from: dt)
    }
}
