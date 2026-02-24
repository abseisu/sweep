// DismissalMemory.swift
// Sweep
//
// Learns from user behavior to predict which emails should and shouldn't surface.
//
// TWO SYSTEMS:
//
// 1. DISMISSAL LEARNING — tracks what the user swipes away to suppress similar items.
//    - By sender domain (e.g. user always dismisses linkedin.com → lower score)
//    - By sender address (e.g. user always dismisses bob@company.com → lower score)
//    - By category (e.g. user always dismisses "social" → lower score)
//    - Each signal is cautious: requires 3+ dismissals before penalizing,
//      decays over 30 days, and never fully suppresses (penalty caps at -30).
//
// 2. ETIQUETTE DEFAULTS — provides baseline writing style context before we learn.
//    - Email: greeting + line-separated paragraphs + sign-off
//    - iMessage: casual, no greeting/sign-off, short and direct
//    - Evolves as StyleMemory collects real examples from the user.
//
// The dismissal signals are included in the AI scoring prompt so the model
// can factor in user behavior when deciding replyability scores.

import Foundation

// MARK: - Data Models

struct DismissalSignal: Codable {
    let key: String           // e.g. "domain:linkedin.com" or "sender:bob@co.com" or "category:social"
    var dismissCount: Int
    var replyCount: Int       // times user replied to this sender/domain (positive signal)
    var lastDismissed: Date
    var lastReplied: Date?
}

// MARK: - DismissalMemory

final class DismissalMemory {

    static let shared = DismissalMemory()
    private init() { load() }

    private let storageKey = "sweep_dismissal_signals"
    private let maxSignals = 200
    private let decayDays: TimeInterval = 30 * 24 * 60 * 60  // 30-day decay

    private(set) var signals: [String: DismissalSignal] = [:]

    // MARK: - Record Events

    /// Called when the user swipes left / dismisses an item
    func recordDismissal(item: LedgerEmail) {
        let domain = domainKey(for: item)
        let sender = senderKey(for: item)
        let category = categoryKey(for: item)

        incrementDismissal(key: domain)
        incrementDismissal(key: sender)
        if let cat = category { incrementDismissal(key: cat) }

        prune()
        save()

        print("📉 DismissalMemory: recorded dismissal — \(item.senderName) (\(domain))")
    }

    /// Called when the user replies to / engages with an item
    func recordReply(item: LedgerEmail) {
        let domain = domainKey(for: item)
        let sender = senderKey(for: item)
        let category = categoryKey(for: item)

        incrementReply(key: domain)
        incrementReply(key: sender)
        if let cat = category { incrementReply(key: cat) }

        save()

        print("📈 DismissalMemory: recorded reply — \(item.senderName) (\(domain))")
    }

    // MARK: - Score Adjustment

    /// Returns a penalty (negative number, -30 to 0) to apply to the replyability score.
    /// Only penalizes after 3+ dismissals with no recent replies.
    func scorePenalty(for item: LedgerEmail) -> Int {
        // iMessages get very minimal penalty — almost always show
        if item.source == .imessage {
            let sender = senderKey(for: item)
            if let signal = activeSignal(for: sender), signal.dismissCount >= 5, signal.replyCount == 0 {
                return -10  // Only suppress iMessage senders after 5+ dismissals with 0 replies
            }
            return 0
        }

        var totalPenalty = 0

        // Check sender-specific (strongest signal)
        let sender = senderKey(for: item)
        if let signal = activeSignal(for: sender) {
            let net = signal.dismissCount - (signal.replyCount * 3)  // Replies count 3x
            if net >= 3 {
                totalPenalty -= min(20, net * 3)  // Max -20 from sender
            }
        }

        // Check domain (weaker signal)
        let domain = domainKey(for: item)
        if let signal = activeSignal(for: domain) {
            let net = signal.dismissCount - (signal.replyCount * 3)
            if net >= 5 {
                totalPenalty -= min(15, net * 2)  // Max -15 from domain
            }
        }

        // Check category (weakest signal)
        if let cat = categoryKey(for: item), let signal = activeSignal(for: cat) {
            let net = signal.dismissCount - (signal.replyCount * 3)
            if net >= 8 {
                totalPenalty -= min(10, net)  // Max -10 from category
            }
        }

        // Cap total penalty
        return max(-30, totalPenalty)
    }

    // MARK: - Prompt Generation

    /// Generates a context section for the AI scoring prompt describing the user's
    /// dismissal patterns. Only includes patterns with 3+ net dismissals.
    func scoringPromptSection() -> String? {
        let now = Date()
        let active = signals.values.filter { now.timeIntervalSince($0.lastDismissed) < decayDays }

        var suppressedSenders: [String] = []
        var suppressedDomains: [String] = []
        var suppressedCategories: [String] = []

        for signal in active {
            let net = signal.dismissCount - (signal.replyCount * 3)
            guard net >= 3 else { continue }

            if signal.key.hasPrefix("sender:") {
                let addr = String(signal.key.dropFirst("sender:".count))
                suppressedSenders.append("\(addr) (dismissed \(signal.dismissCount)x)")
            } else if signal.key.hasPrefix("domain:") {
                let dom = String(signal.key.dropFirst("domain:".count))
                suppressedDomains.append("\(dom) (dismissed \(signal.dismissCount)x)")
            } else if signal.key.hasPrefix("category:") {
                let cat = String(signal.key.dropFirst("category:".count))
                suppressedCategories.append("\(cat) (dismissed \(signal.dismissCount)x)")
            }
        }

        guard !suppressedSenders.isEmpty || !suppressedDomains.isEmpty || !suppressedCategories.isEmpty else {
            return nil
        }

        var lines: [String] = ["USER DISMISSAL PATTERNS (lower replyability for these — the user rarely engages):"]
        if !suppressedSenders.isEmpty {
            lines.append("Frequently dismissed senders: \(suppressedSenders.prefix(10).joined(separator: ", "))")
        }
        if !suppressedDomains.isEmpty {
            lines.append("Frequently dismissed domains: \(suppressedDomains.prefix(10).joined(separator: ", "))")
        }
        if !suppressedCategories.isEmpty {
            lines.append("Frequently dismissed categories: \(suppressedCategories.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Etiquette Defaults

    /// Returns default etiquette context based on the message source.
    /// This provides good defaults before StyleMemory has learned the user's style.
    /// Once StyleMemory has enough examples, its output takes precedence.
    static func etiquetteDefaults(for source: LedgerSource, hasStyleProfile: Bool) -> String? {
        // If StyleMemory already has a profile, it knows the user's style — skip defaults
        if hasStyleProfile { return nil }

        switch source {
        case .gmail, .outlook:
            return """
            DEFAULT EMAIL ETIQUETTE (use until you learn the user's actual style):
            - Start with a greeting (e.g. "Hi [Name]," or "Hey [Name],")
            - Use line-separated paragraphs — never write a wall of text
            - Keep it warm but professional
            - End with a brief sign-off (e.g. "Best," or "Thanks,")
            - Use proper grammar and punctuation
            - Match the formality of the sender's email
            """

        case .imessage:
            return """
            DEFAULT iMESSAGE ETIQUETTE (use until you learn the user's actual style):
            - No greeting or sign-off — dive straight in
            - Keep it short and conversational (1-3 sentences)
            - Casual tone — contractions, lowercase OK
            - Match the energy/tone of the sender's message
            - Don't over-formalize — it's texting
            """

        case .slack, .teams:
            return """
            DEFAULT MESSAGING ETIQUETTE (use until you learn the user's actual style):
            - Brief and to the point
            - Professional but conversational
            - No formal greeting/sign-off needed
            - OK to use emoji sparingly if the sender does
            """

        case .telegram, .groupme:
            return """
            DEFAULT CHAT ETIQUETTE (use until you learn the user's actual style):
            - Short and casual
            - Match the group's energy
            - No formal structure needed
            """
        }
    }

    // MARK: - Private Helpers

    private func domainKey(for item: LedgerEmail) -> String {
        let domain = item.senderEmail.lowercased().components(separatedBy: "@").last ?? "unknown"
        return "domain:\(domain)"
    }

    private func senderKey(for item: LedgerEmail) -> String {
        return "sender:\(item.senderEmail.lowercased())"
    }

    private func categoryKey(for item: LedgerEmail) -> String? {
        guard let cat = item.category, !cat.isEmpty else { return nil }
        return "category:\(cat.lowercased())"
    }

    private func incrementDismissal(key: String) {
        if var signal = signals[key] {
            signal.dismissCount += 1
            signal.lastDismissed = Date()
            signals[key] = signal
        } else {
            signals[key] = DismissalSignal(
                key: key, dismissCount: 1, replyCount: 0,
                lastDismissed: Date(), lastReplied: nil
            )
        }
    }

    private func incrementReply(key: String) {
        if var signal = signals[key] {
            signal.replyCount += 1
            signal.lastReplied = Date()
            signals[key] = signal
        } else {
            signals[key] = DismissalSignal(
                key: key, dismissCount: 0, replyCount: 1,
                lastDismissed: Date.distantPast, lastReplied: Date()
            )
        }
    }

    /// Returns the signal if it's still within the decay window
    private func activeSignal(for key: String) -> DismissalSignal? {
        guard let signal = signals[key] else { return nil }
        let age = Date().timeIntervalSince(signal.lastDismissed)
        guard age < decayDays else { return nil }
        return signal
    }

    private func prune() {
        let now = Date()
        // Remove signals older than decay period
        signals = signals.filter { now.timeIntervalSince($0.value.lastDismissed) < decayDays }
        // If still too many, keep the most active
        if signals.count > maxSignals {
            let sorted = signals.sorted { $0.value.dismissCount > $1.value.dismissCount }
            signals = Dictionary(uniqueKeysWithValues: sorted.prefix(maxSignals).map { ($0.key, $0.value) })
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(signals) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([String: DismissalSignal].self, from: data) else { return }
        signals = loaded
        print("📉 DismissalMemory: loaded \(signals.count) signals")
    }

    /// Reset all learned signals (e.g. fresh start)
    func reset() {
        signals.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

