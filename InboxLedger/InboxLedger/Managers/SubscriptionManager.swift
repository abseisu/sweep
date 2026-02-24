// SubscriptionManager.swift
// Ledger
//
// Manages subscription tiers, 7-day Pro trial, and feature gating.
//
// TIERS:
//   Ledger Lite  — Free   — 5 cards/day, OpenAI drafts, style learning, unlimited redrafts
//   Ledger       — $4.99  — Unlimited cards, calendar awareness, batch notifications
//   Ledger Pro   — $9.99  — Adds Claude gray-zone scoring + Claude escalated redrafts + per-contact style
//
// TRIAL:
//   All new users get 7 days of Ledger Pro. After trial, reverts to Ledger Lite.
//
// QUALITY MODEL:
//   All tiers use OpenAI for scoring and drafts (same quality).
//   Pro adds Claude for gray-zone re-scoring and escalated redrafts.
//   Free users are limited by volume (5 cards/day), not quality.
//
// TESTING: Use the Settings tier picker to switch between all tiers freely.

import Foundation

enum SubscriptionTier: String, Codable, CaseIterable {
    case free = "free"           // Ledger Lite
    case standard = "standard"   // Ledger — $4.99/mo
    case pro = "pro"             // Ledger Pro — $9.99/mo
}

final class SubscriptionManager: ObservableObject {

    static let shared = SubscriptionManager()
    private init() { loadState() }

    // ── Current State ──
    @Published private(set) var tier: SubscriptionTier = .pro
    @Published private(set) var isTrialActive: Bool = false
    @Published private(set) var trialDaysRemaining: Int = 0

    /// The effective tier (trial overrides stored tier)
    var effectiveTier: SubscriptionTier {
        if isTrialActive && tier == .free { return .pro }
        return tier
    }

    // MARK: - Feature Gates

    /// Whether Claude is used for gray-zone re-scoring (Pro only)
    var claudeScoringEnabled: Bool { effectiveTier == .pro }

    /// Whether redrafts escalate to Claude after 2+ attempts (Pro only)
    var claudeRedraftEnabled: Bool { effectiveTier == .pro }

    /// Whether per-contact style memory is active (Pro only)
    var perContactStyleEnabled: Bool { effectiveTier == .pro }

    /// Whether style learning is active at all (all tiers)
    var styleLearningEnabled: Bool { true }

    /// Whether redrafts are available (all tiers — unlimited)
    var redraftsEnabled: Bool { true }

    /// Max cards per day (Lite = 5, Standard/Pro = unlimited)
    var maxEmailsPerWindow: Int {
        switch effectiveTier {
        case .free:     return 5
        case .standard: return 999
        case .pro:      return 999
        }
    }

    /// Unlimited redrafts for all tiers
    var maxRedraftsPerCard: Int { 99 }

    /// Whether calendar awareness is available (Standard+)
    var calendarEnabled: Bool { effectiveTier == .standard || effectiveTier == .pro }

    /// Whether batch/urgent notifications are enabled (Standard+)
    var urgentNotificationsEnabled: Bool { effectiveTier == .standard || effectiveTier == .pro }

    /// Whether the user is on any paid plan (or trial)
    var isPaid: Bool { effectiveTier == .standard || effectiveTier == .pro }

    // MARK: - Display Info

    var tierDisplayName: String {
        if isTrialActive && tier == .free { return "Ledger Pro Trial" }
        switch tier {
        case .free:     return "Ledger Lite"
        case .standard: return "Ledger"
        case .pro:      return "Ledger Pro"
        }
    }

    var tierDescription: String {
        if isTrialActive && tier == .free {
            return "\(trialDaysRemaining) day\(trialDaysRemaining == 1 ? "" : "s") left in your free Pro trial. Unlimited cards, near-frontier drafts, calendar awareness, and per-contact voice."
        }
        switch tier {
        case .free:
            return "5 cards per day with quality AI drafts, style learning, and unlimited redrafts."
        case .standard:
            return "Unlimited cards with quality AI drafts, calendar-aware scheduling, and batch notifications."
        case .pro:
            return "Unlimited cards with a near-frontier AI blend, per-contact voice, and cutting-edge draft escalation."
        }
    }

    /// Short subtitle for upgrade prompts
    var upgradePrompt: String? {
        if isTrialActive && tier == .free { return nil }
        switch tier {
        case .free:
            return "Upgrade to Ledger for unlimited cards"
        case .standard:
            return "Upgrade to Pro for near-frontier AI & per-contact voice"
        case .pro:
            return nil
        }
    }

    // MARK: - Pricing

    static let standardMonthly = "$4.99"
    static let standardYearly = "$36.99"
    static let standardYearlySavings = "Save 38%"

    static let proMonthly = "$9.99"
    static let proYearly = "$79.99"
    static let proYearlySavings = "Save 33%"

    // MARK: - Trial Logic

    private let trialStartKey = "ledger_trial_start"
    private let trialDuration: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    /// Start the Pro trial (called once during first run)
    func startTrialIfNeeded() {
        guard UserDefaults.standard.object(forKey: trialStartKey) == nil else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: trialStartKey)
        isTrialActive = true
        trialDaysRemaining = 7
        print("🎁 Pro trial started — 7 days")
    }

    private func checkTrialStatus() {
        guard let startTimestamp = UserDefaults.standard.object(forKey: trialStartKey) as? Double else {
            isTrialActive = false
            trialDaysRemaining = 0
            return
        }

        let elapsed = Date().timeIntervalSince1970 - startTimestamp
        if elapsed < trialDuration {
            isTrialActive = true
            trialDaysRemaining = max(1, Int(ceil((trialDuration - elapsed) / (24 * 60 * 60))))
        } else {
            isTrialActive = false
            trialDaysRemaining = 0
        }
    }

    // MARK: - Persistence

    private let tierKey = "ledger_subscription_tier"

    private func loadState() {
        if let raw = UserDefaults.standard.string(forKey: tierKey),
           let saved = SubscriptionTier(rawValue: raw) {
            tier = saved
        } else {
            tier = .free
        }
        checkTrialStatus()
    }

    /// Called after StoreKit purchase or testing toggle
    func setTier(_ newTier: SubscriptionTier) {
        tier = newTier
        UserDefaults.standard.set(newTier.rawValue, forKey: tierKey)
        checkTrialStatus()
        objectWillChange.send()
    }

    /// Restore to free (e.g. subscription expired)
    func expireSubscription() {
        setTier(.free)
    }

    /// For testing: reset trial so it can be started again
    func resetTrial() {
        UserDefaults.standard.removeObject(forKey: trialStartKey)
        checkTrialStatus()
        objectWillChange.send()
        print("🧪 Trial reset")
    }
}
