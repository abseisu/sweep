// AppState.swift
// Ledger

import Foundation
import SwiftUI

// MARK: - AI Score Cache

struct CachedAIScore {
    let replyability: Int
    let summary: String?
    let draft: String?
    let tone: String?
    let category: String?
    let suggestReplyAll: Bool
    let timestamp: Date
}

// MARK: - Ledger Mode

/// A reply queued for delayed sending (undo-send window)
struct PendingSendItem {
    let email: LedgerEmail
    let body: String
    let replyAll: Bool
    let queuedAt: Date
    let contactName: String
}

/// How the user interacts with their daily stack.
/// - `.window`: Classic mode — one-hour window opens at a set time each day
/// - `.stack`: Always-on mode — stack is always accessible, smart batch notifications
enum LedgerMode: String, Codable, CaseIterable {
    case window = "window"
    case stack = "stack"

    var title: String {
        switch self {
        case .window: return "Evening Window"
        case .stack:  return "Smart Stack"
        }
    }

    var subtitle: String {
        switch self {
        case .window: return "One hour per day at a set time. Forced focus."
        case .stack:  return "Always available. Notified when a batch is ready."
        }
    }
}

@MainActor
final class AppState: ObservableObject {

    // MARK: - Mode
    @Published var ledgerMode: LedgerMode = .stack

    // MARK: - Accounts (multi-account)
    @Published var accounts: [ConnectedAccount] = []
    @Published var imessageEnabled: Bool = false
    @Published var imessageRelayConnected: Bool = false
    @Published var imessageRelayMacName: String? = nil
    @Published var hasCompletedOnboarding: Bool = false

    // MARK: - Items
    @Published var items: [LedgerEmail] = []
    @Published var dismissedItems: [LedgerEmail] = []
    var dismissedIds: Set<String> = []              // Persisted across sessions
    var dismissedThreadIds: Set<String> = []         // iMessage threadIds — prevents resurface
    @Published var snoozedItems: [LedgerEmail] = []
    @Published var isLoading: Bool = false
    @Published var isProcessingAI: Bool = false
    @Published var isScanningNewAccount: String? = nil  // Service label while scanning, nil when done
    /// Tracks whether we've already done the initial fetch for this window/session
    var hasFetchedThisWindow: Bool = false
    /// Timestamp of the last completed fetch — "Check again" scans from here
    var lastFetchTimestamp: Date? = nil
    /// Whether the very first ledger run has ever been completed.
    /// First run looks back 7 days; all subsequent runs use normal windows (24h or incremental).
    @Published var hasCompletedFirstRun: Bool = false
    /// True while the first-ever 7-day scan is in progress (for UI messaging)
    @Published var isFirstRunActive: Bool = false
    /// True during the session where the first run just completed (for showing explainer banner)
    @Published var isFirstSession: Bool = false
    /// Set when user switches modes mid-session (for "continuing from" banner). Nil if no switch happened.
    @Published var switchedFromMode: LedgerMode? = nil

    // MARK: - Window Pre-fetch
    /// Whether we've already prefetched for today's upcoming window (prevents redundant fetches)
    private var hasPrefetchedForWindow: Bool = false
    /// How many minutes before the window to start the background fetch
    private let prefetchLeadMinutes: Double = 5

    // MARK: - AI Score Cache
    /// Caches AI scores by email ID for 24 hours to prevent scoring variance across runs.
    /// Key: email ID, Value: (replyability, summary, draft, tone, category, suggestReplyAll, timestamp)
    private var aiScoreCache: [String: CachedAIScore] = [:]
    private let scoreCacheMaxAge: TimeInterval = 24 * 60 * 60  // 24 hours

    // MARK: - Undo Send
    /// A queued send that hasn't actually been dispatched yet (10s delay for undo)
    @Published var pendingSend: PendingSendItem? = nil
    /// Countdown seconds remaining on the pending send
    @Published var pendingSendCountdown: Int = 0
    private var pendingSendTimer: Timer? = nil
    /// How long to wait before actually sending (seconds)
    let undoSendWindow: Int = 10

    // MARK: - Stack Mode State
    /// Estimated minutes to clear current stack (based on card count)
    var estimatedClearMinutes: Int {
        let count = items.count
        if count == 0 { return 0 }
        // ~1.5 min per card on average (some swipe-send, some edit)
        return max(1, Int(ceil(Double(count) * 1.5)))
    }
    /// Timestamp of last batch notification sent (prevent spam)
    var lastBatchNotificationDate: Date? = nil
    /// Number of cards in stack when last batch notification was sent
    var lastBatchNotificationCount: Int = 0
    /// Whether user has cleared today's stack at least once
    @Published var hasClearedToday: Bool = false
    /// Background fetch timer for stack mode
    private var stackRefreshTimer: Timer?

    // MARK: - Time Lock
    @Published var notificationHour: Int = 21
    @Published var notificationMinute: Int = 0
    @Published var isUnlocked: Bool = false
    @Published var lockExpiresAt: Date? = nil
    @Published var windowConflict: WindowConflictSuggestion? = nil
    private var lockTimer: Timer?
    private var autoUnlockTimer: Timer?
    /// The date string (yyyy-MM-dd) of the last window that was opened
    private var lastWindowDate: String = ""
    /// Whether the user has postponed today's window
    private var hasPostponedToday: Bool = false
    /// The postponed time (if any) — temporary override for today only
    @Published var postponedHour: Int? = nil
    @Published var postponedMinute: Int? = nil

    // MARK: - Signature
    @Published var emailSignature: String = ""
    /// When true, Ledger appends its own name signature to replies. When false, relies on the user's email provider signature.
    @Published var appendLedgerSignature: Bool = true
    /// Cached provider signatures keyed by account ID (fetched from Gmail/Outlook APIs)
    @Published var providerSignatures: [String: String] = [:]
    /// When enabled, marks the original email as read in Gmail/Outlook after sending a reply
    @Published var markAsReadAfterReply: Bool = true

    // MARK: - Snooze
    /// How many hours to snooze an email (user-configurable, default 24)
    @Published var snoozeHours: Int = 6

    /// Names of people you've recently corresponded with (for lock screen nudges)
    var recentContactNames: [String] {
        // Combine current items + dismissed items, deduplicate, take recent unique names
        let all = (items + dismissedItems)
            .sorted { $0.date > $1.date }
            .map { $0.senderName }
            .filter { !$0.isEmpty && $0 != "Unknown" }
        var seen = Set<String>()
        var unique: [String] = []
        for name in all {
            if !seen.contains(name) {
                seen.insert(name)
                unique.append(name)
            }
            if unique.count >= 15 { break }
        }
        return unique
    }

    // MARK: - Computed

    var hasSources: Bool { !accounts.isEmpty || imessageEnabled }
    var isReady: Bool { hasSources && hasCompletedOnboarding }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "ledger_onboarded")
        saveMode()
        // Clear any mode switch date so the user gets a free switch on day one
        lastModeSwitchDate = ""
        // Start the 7-day Pro trial
        SubscriptionManager.shared.startTrialIfNeeded()

        if ledgerMode == .stack {
            // Stack mode: immediately ready, no lock
            isUnlocked = true
        } else {
            // Window mode: check if we should unlock now
            let cal = Calendar.current
            let now = Date()
            let todayComponents = cal.dateComponents([.year, .month, .day], from: now)
            var fireComponents = DateComponents()
            fireComponents.year = todayComponents.year
            fireComponents.month = todayComponents.month
            fireComponents.day = todayComponents.day
            fireComponents.hour = notificationHour
            fireComponents.minute = notificationMinute

            if let fireTime = cal.date(from: fireComponents) {
                let windowEnd = fireTime.addingTimeInterval(3600)
                if now > windowEnd {
                    lastWindowDate = todayString
                    UserDefaults.standard.set(lastWindowDate, forKey: "ledger_last_window")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.checkAutoUnlock()
            }
            startAutoUnlockTimer()
        }
    }

    /// In window mode, locked when outside the hour. In stack mode, never locked.
    var isLocked: Bool {
        if ledgerMode == .stack { return false }
        return !isUnlocked
    }

    func accounts(for service: AccountService) -> [ConnectedAccount] {
        accounts.filter { $0.service == service }
    }

    var enabledAccounts: [ConnectedAccount] {
        accounts.filter { $0.isEnabled }
    }

    var unlockTimeDescription: String {
        let cal = Calendar.current
        var components = DateComponents()
        components.hour = effectiveHour
        components.minute = effectiveMinute
        guard let nextFire = cal.nextDate(after: Date(), matching: components, matchingPolicy: .nextTime) else {
            return "\(notificationHour):\(String(format: "%02d", notificationMinute))"
        }
        let diff = cal.dateComponents([.hour, .minute], from: Date(), to: nextFire)
        if let h = diff.hour, let m = diff.minute {
            if h == 0 { return "in \(m)m" }
            return "in \(h)h \(m)m"
        }
        return "tonight"
    }

    var timeRemainingDescription: String? {
        guard let expires = lockExpiresAt else { return nil }
        let remaining = expires.timeIntervalSince(Date())
        if remaining <= 0 { return nil }
        let minutes = Int(remaining / 60)
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        return "\(minutes)m left"
    }

    // MARK: - Managers
    let gmailManager = GmailManager()
    let outlookManager = OutlookManager()
    let slackManager = SlackManager()
    let telegramManager = TelegramManager()
    let groupMeManager = GroupMeManager()
    let messageManager = MessageManager()
    let aiManager = AIManager()

    init() {
        // Load mode
        if let rawMode = UserDefaults.standard.string(forKey: "ledger_mode"),
           let savedMode = LedgerMode(rawValue: rawMode) {
            ledgerMode = savedMode
        }
        emailSignature = UserDefaults.standard.string(forKey: "ledger_signature") ?? ""
        appendLedgerSignature = UserDefaults.standard.object(forKey: "ledger_append_signature") as? Bool ?? true
        markAsReadAfterReply = UserDefaults.standard.object(forKey: "ledger_mark_read") as? Bool ?? true
        if UserDefaults.standard.object(forKey: "ledger_snooze_hours") != nil {
            snoozeHours = UserDefaults.standard.integer(forKey: "ledger_snooze_hours")
        }
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "ledger_onboarded")
        hasCompletedFirstRun = UserDefaults.standard.bool(forKey: "ledger_first_run_done")
        // Load saved schedule (window mode)
        if UserDefaults.standard.object(forKey: "ledger_hour") != nil {
            notificationHour = UserDefaults.standard.integer(forKey: "ledger_hour")
            notificationMinute = UserDefaults.standard.integer(forKey: "ledger_minute")
        }
        lastWindowDate = UserDefaults.standard.string(forKey: "ledger_last_window") ?? ""
        lastBatchNotificationDate = UserDefaults.standard.object(forKey: "ledger_last_batch_notif") as? Date
        if UserDefaults.standard.object(forKey: "ledger_batch_sensitivity") != nil {
            batchSensitivity = UserDefaults.standard.integer(forKey: "ledger_batch_sensitivity")
        }
        loadAccounts()
        loadDismissedIds()
        loadDismissedThreadIds()

        if ledgerMode == .window {
            checkAutoUnlock()
            checkWindowConflict()
            startAutoUnlockTimer()
        }

        // Generate custom notification sound file (once, on first launch)
        SoundManager.shared.generateNotificationSoundFile()
    }

    // MARK: - Mode

    func saveMode() {
        UserDefaults.standard.set(ledgerMode.rawValue, forKey: "ledger_mode")
        Task { await BackendManager.shared.syncSettings(.init(
            mode: ledgerMode.rawValue, windowHour: nil, windowMinute: nil,
            sensitivity: nil, snoozeHours: nil, scoreThreshold: nil, scanIntervalMinutes: nil
        )) }
    }

    /// Date of the last mode switch — persisted so it survives app restarts
    private var lastModeSwitchDate: String {
        get { UserDefaults.standard.string(forKey: "ledger_last_mode_switch") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ledger_last_mode_switch") }
    }

    /// Whether the user has already switched modes today
    var hasUsedModeSwitchToday: Bool {
        lastModeSwitchDate == todayString
    }

    /// Attempts to switch mode. Returns false if rate-limited (already switched today).
    /// Caller should show confirmation dialog BEFORE calling this.
    @discardableResult
    func switchMode(to mode: LedgerMode) -> Bool {
        let previousMode = ledgerMode
        guard mode != previousMode else { return true }

        // Rate limit: one switch per day — but ONLY after onboarding is complete
        if hasCompletedOnboarding && hasUsedModeSwitchToday {
            print("⚠️ Mode switch blocked — already switched today")
            return false
        }

        // Record the switch date (only post-onboarding)
        if hasCompletedOnboarding {
            lastModeSwitchDate = todayString
        }

        ledgerMode = mode
        saveMode()

        // Clear session state from previous mode
        isFirstSession = false
        dismissedItems = []
        snoozedItems = []
        switchedFromMode = previousMode  // Track for UI banner
        clearLedgerState()  // Previous mode's state is stale

        // Clear dismissed IDs when switching to stack (legacy dismissals from window mode)
        if mode == .stack {
            pruneExpiredDismissals()
        }

        if mode == .stack {
            // Stack mode: always unlocked, no timers needed
            lockTimer?.invalidate()
            autoUnlockTimer?.invalidate()
            lockExpiresAt = nil
            windowConflict = nil
            if !isUnlocked { isUnlocked = true }
            // Fetch immediately in stack mode
            hasFetchedThisWindow = false
            Task { await fetchAndProcess() }
        } else {
            // Window mode: lock first, then check if we're in the window
            lockExpiresAt = nil
            isUnlocked = false  // Lock immediately — checkAutoUnlock will unlock if within window
            hasFetchedThisWindow = false
            items = []  // Clear stack items — window will fetch its own

            if previousMode == .stack {
                // Small delay so Settings sheet isn't forcibly dismissed by the lock screen transition
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.checkAutoUnlock()
                    self?.checkWindowConflict()
                    self?.startAutoUnlockTimer()
                    // Only fetch if we're actually unlocked (within the window)
                    if self?.isUnlocked == true {
                        self?.hasFetchedThisWindow = false
                        Task { await self?.fetchAndProcess() }
                    }
                }
            }
        }
        return true
    }

    /// Checks every 30 seconds if the window should open while user is on the lock screen
    private func startAutoUnlockTimer() {
        autoUnlockTimer?.invalidate()
        autoUnlockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isUnlocked && !self.hasUsedTodaysWindow {
                // Check if it's time to prefetch (5 min before window)
                self.checkPrefetch()
                // Check if it's time to unlock
                self.checkAutoUnlock()
            }
            // Refresh conflict suggestion periodically
            self.checkWindowConflict()
        }
    }

    /// Check if today's window conflicts with a calendar event and suggest an alternative
    func checkWindowConflict() {
        guard !isUnlocked, !hasUsedTodaysWindow else {
            windowConflict = nil
            return
        }
        // Don't re-show if user already dismissed today
        if UserDefaults.standard.string(forKey: "ledger_conflict_dismissed") == todayString {
            windowConflict = nil
            return
        }
        let conflict = CalendarManager.shared.windowConflict(hour: effectiveHour, minute: effectiveMinute)
        windowConflict = conflict

        // Schedule a notification 30 min before the window if there's a conflict
        if let conflict = conflict {
            NotificationManager.shared.scheduleConflictNotification(suggestion: conflict)
            print("📅 Calendar conflict: \(conflict.message)")
        } else {
            NotificationManager.shared.cancelConflictNotification()
        }
    }

    func saveSignature() {
        UserDefaults.standard.set(emailSignature, forKey: "ledger_signature")
        UserDefaults.standard.set(appendLedgerSignature, forKey: "ledger_append_signature")
    }

    func saveMarkAsReadSetting() {
        UserDefaults.standard.set(markAsReadAfterReply, forKey: "ledger_mark_read")
    }

    // MARK: - Stack Mode Notifications

    /// User-configurable batch sensitivity (1–3). Persisted.
    /// 1 = Fewer interruptions, 2 = Balanced, 3 = More responsive
    @Published var batchSensitivity: Int = 2

    /// Weighted threshold for each sensitivity level
    private var batchWeightThreshold: Int {
        switch batchSensitivity {
        case 1:  return 12  // ~4 must-reply or ~12 worth-a-reply
        case 3:  return 4   // ~2 must-reply or ~4 worth-a-reply
        default: return 8   // ~3 must-reply or ~8 worth-a-reply (balanced)
        }
    }

    /// Minimum hours between batch notifications to avoid spam
    private var batchCooldownHours: Double {
        switch batchSensitivity {
        case 1:  return 5
        case 3:  return 2
        default: return 3
        }
    }

    /// Current batch weight based on card priorities
    var currentBatchWeight: Int {
        items.reduce(0) { total, item in
            total + (item.replyability >= 70 ? 3 : 1)
        }
    }

    /// Human-readable batch status
    var batchStatusDescription: String {
        let mustCount = items.filter { $0.priority == .must }.count
        let otherCount = items.count - mustCount
        if mustCount > 0 && otherCount > 0 {
            return "\(mustCount) need a reply, plus \(otherCount) others"
        } else if mustCount > 0 {
            return "\(mustCount) need a reply"
        } else if otherCount > 0 {
            return "\(otherCount) worth a reply"
        }
        return "No messages waiting"
    }

    func saveBatchSensitivity() {
        UserDefaults.standard.set(batchSensitivity, forKey: "ledger_batch_sensitivity")
        Task { await BackendManager.shared.syncSettings(.init(
            mode: nil, windowHour: nil, windowMinute: nil,
            sensitivity: batchSensitivity, snoozeHours: nil, scoreThreshold: nil, scanIntervalMinutes: nil
        )) }
    }

    /// Checks if the current stack warrants a batch notification.
    /// Called after each background fetch cycle in stack mode.
    func evaluateStackNotification() {
        guard ledgerMode == .stack else { return }
        guard !items.isEmpty else { return }

        let now = Date()

        // Check for urgent items first (replyability 90+, time-sensitive)
        let urgentItems = items.filter { $0.replyability >= 90 }
        for item in urgentItems {
            let notifiedKey = "ledger_urgent_notified_\(item.id)"
            if !UserDefaults.standard.bool(forKey: notifiedKey) {
                UserDefaults.standard.set(true, forKey: notifiedKey)
                NotificationManager.shared.sendUrgentNotification(
                    sender: item.senderName,
                    subject: item.subject,
                    summary: item.aiSummary ?? item.snippet
                )
            }
        }

        // Batch notification: weighted score must exceed threshold
        let weight = currentBatchWeight
        guard weight >= batchWeightThreshold else { return }

        // Cooldown: don't send batch notifications too frequently
        if let lastBatch = lastBatchNotificationDate {
            let hoursSinceLast = now.timeIntervalSince(lastBatch) / 3600
            if hoursSinceLast < batchCooldownHours { return }
        }

        // Don't re-notify if the stack hasn't grown meaningfully since last notification
        if items.count <= lastBatchNotificationCount + 2 { return }

        // Send the batch notification
        lastBatchNotificationDate = now
        lastBatchNotificationCount = items.count
        UserDefaults.standard.set(now, forKey: "ledger_last_batch_notif")

        let mustCount = items.filter { $0.priority == .must }.count
        NotificationManager.shared.sendBatchNotification(
            cardCount: items.count,
            mustReplyCount: mustCount,
            estimatedMinutes: estimatedClearMinutes
        )
    }

    /// Called when user opens the app in stack mode.
    /// First open: full 24h fetch. Subsequent opens: incremental scan since last fetch.
    func stackModeAppOpened() async {
        guard ledgerMode == .stack else { return }

        if !hasFetchedThisWindow {
            // First fetch this session — full 24h lookback
            await fetchAndProcess()
        } else {
            // Already fetched this session — incremental check for new emails only
            let staleThreshold: TimeInterval = 30 * 60  // 30 minutes
            if (lastFetchTimestamp?.timeIntervalSinceNow ?? -staleThreshold * 2) < -staleThreshold {
                await checkForNewItems()
            }
        }
    }

    /// Invalidate the stack-mode background refresh timer (e.g. when entering background)
    func stopStackRefreshTimer() {
        stackRefreshTimer?.invalidate()
        stackRefreshTimer = nil
    }

    /// Fetches email signatures from Gmail and Outlook for all connected accounts.
    /// Gmail has a server-side signature accessible via API.
    /// Outlook signatures are client-side only and not available via Graph API.
    func fetchProviderSignatures() async {
        for account in enabledAccounts {
            switch account.service {
            case .gmail:
                let token = await freshToken(for: account)
                if let sig = await gmailManager.fetchSignature(accessToken: token, email: account.identifier) {
                    providerSignatures[account.id] = sig
                    print("📝 Gmail signature loaded for \(account.identifier): \(sig.prefix(50))…")
                }
            case .outlook:
                // Outlook compose signatures are stored client-side, not accessible via Graph API
                // The /reply endpoint appends the signature automatically
                break
            default:
                break
            }
        }
    }

    /// Get the provider signature for a specific email item's account
    func providerSignature(for item: LedgerEmail) -> String? {
        providerSignatures[item.accountId]
    }

    // MARK: - Account Persistence

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "ledger_accounts")
        }
        // Update calendar manager so it knows which API sources are available
        CalendarManager.shared.updateAccountFlags(
            hasGmail: accounts.contains(where: { $0.service == .gmail && $0.isEnabled }),
            hasOutlook: accounts.contains(where: { $0.service == .outlook && $0.isEnabled })
        )
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: "ledger_accounts"),
              let saved = try? JSONDecoder().decode([ConnectedAccount].self, from: data) else { return }
        accounts = saved
        CalendarManager.shared.updateAccountFlags(
            hasGmail: accounts.contains(where: { $0.service == .gmail && $0.isEnabled }),
            hasOutlook: accounts.contains(where: { $0.service == .outlook && $0.isEnabled })
        )
    }

    // MARK: - Time Lock Logic

    // MARK: - Schedule Persistence

    func saveSchedule() {
        UserDefaults.standard.set(notificationHour, forKey: "ledger_hour")
        UserDefaults.standard.set(notificationMinute, forKey: "ledger_minute")
        NotificationManager.shared.scheduleNightlyReminder(hour: notificationHour, minute: notificationMinute)
        Task { await BackendManager.shared.syncSettings(.init(
            mode: nil, windowHour: notificationHour, windowMinute: notificationMinute,
            sensitivity: nil, snoozeHours: nil, scoreThreshold: nil, scanIntervalMinutes: nil
        )) }
    }

    private var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Has the user already used (or missed) today's window?
    var hasUsedTodaysWindow: Bool {
        lastWindowDate == todayString
    }

    // MARK: - Time Lock Logic

    /// Silently fetches and scores emails ~5 min before the scheduled window.
    /// When the window opens, items are already loaded — no spinner.
    private func checkPrefetch() {
        guard ledgerMode == .window else { return }
        guard !hasPrefetchedForWindow else { return }
        guard !isLoading else { return }

        let cal = Calendar.current
        let now = Date()
        let todayComponents = cal.dateComponents([.year, .month, .day], from: now)
        var fireComponents = DateComponents()
        fireComponents.year = todayComponents.year
        fireComponents.month = todayComponents.month
        fireComponents.day = todayComponents.day
        fireComponents.hour = effectiveHour
        fireComponents.minute = effectiveMinute
        guard let fireTime = cal.date(from: fireComponents) else { return }

        // Only prefetch if we're within the lead window (e.g. 5 min before)
        let prefetchStart = fireTime.addingTimeInterval(-prefetchLeadMinutes * 60)
        guard now >= prefetchStart && now < fireTime else { return }

        hasPrefetchedForWindow = true
        print("⏰ Pre-fetching for window at \(effectiveHour):\(String(format: "%02d", effectiveMinute)) — \(Int(fireTime.timeIntervalSince(now)))s until open")

        Task {
            await fetchAndProcess()
            // Mark as fetched so DashboardView.onAppear skips re-fetch
            hasFetchedThisWindow = true
            print("⏰ Pre-fetch complete — ledger ready with \(items.count) items")
        }
    }

    func checkAutoUnlock() {
        // If already unlocked, nothing to do
        guard !isUnlocked else { return }

        // If today's window was already used (including opened early), stay locked until tomorrow
        guard !hasUsedTodaysWindow else { return }

        let cal = Calendar.current
        let now = Date()
        let todayComponents = cal.dateComponents([.year, .month, .day], from: now)
        var fireComponents = DateComponents()
        fireComponents.year = todayComponents.year
        fireComponents.month = todayComponents.month
        fireComponents.day = todayComponents.day
        fireComponents.hour = effectiveHour
        fireComponents.minute = effectiveMinute
        guard let fireTime = cal.date(from: fireComponents) else { return }
        let windowEnd = fireTime.addingTimeInterval(3600)

        // If we're currently within the hour window, unlock (or re-unlock after app restart)
        if now >= fireTime && now <= windowEnd {
            unlock(expiresAt: windowEnd)
            return
        }

        // Also check if we have a persisted window that's still active
        // (handles force-quit + relaunch during a postponed window)
        if let savedExpiry = UserDefaults.standard.object(forKey: "ledger_window_expires") as? Date,
           now < savedExpiry {
            unlock(expiresAt: savedExpiry)
            return
        }
        // If the window already passed, hasUsedTodaysWindow keeps it locked until tomorrow
    }

    func unlock(expiresAt: Date) {
        isUnlocked = true
        lockExpiresAt = expiresAt
        // Mark today's window as used
        lastWindowDate = todayString
        UserDefaults.standard.set(lastWindowDate, forKey: "ledger_last_window")
        // Persist expiry so force-quit + relaunch can restore
        UserDefaults.standard.set(expiresAt, forKey: "ledger_window_expires")

        // Stop nagging — user opened the app
        NotificationManager.shared.cancelAllNags()

        lockTimer?.invalidate()
        lockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if Date() >= expiresAt { self.lock() }
                self.objectWillChange.send()
            }
        }
    }

    func lock() {
        isUnlocked = false
        lockExpiresAt = nil
        lockTimer?.invalidate()
        lockTimer = nil
        hasFetchedThisWindow = false
        hasPrefetchedForWindow = false
        lastFetchTimestamp = nil
        ledgerWasCleared = false
        sessionReplyContacts = []
        sessionReplyCount = 0
        // Clear persisted ledger state (stale after window closes)
        clearLedgerState()
        // Clear persisted window expiry
        UserDefaults.standard.removeObject(forKey: "ledger_window_expires")
        // Reset postpone state for tomorrow
        hasPostponedToday = false
        postponedHour = nil
        postponedMinute = nil
    }

    // MARK: - Open Early / Postpone

    /// Opens the ledger window right now, lasting 1 hour. Uses today's one window.
    func openEarly() {
        guard !hasUsedTodaysWindow else { return }
        let windowEnd = Date().addingTimeInterval(3600)
        unlock(expiresAt: windowEnd)
        // Reschedule notifications for next day since we used today's window early
        NotificationManager.shared.scheduleNightlyReminder(hour: notificationHour, minute: notificationMinute)
    }

    /// Whether postpone is available from notification (one quick postpone per day)
    var canPostpone: Bool {
        !hasPostponedToday && !hasUsedTodaysWindow
    }

    /// Postpone the window by 1 hour. Can only be done once per day.
    /// Used by the notification action (quick postpone).
    func postponeWindow() {
        guard canPostpone else { return }

        let currentHour = postponedHour ?? notificationHour
        let currentMinute = postponedMinute ?? notificationMinute

        // Add 1 hour
        let newHour = (currentHour + 1) % 24
        postponeToTime(hour: newHour, minute: currentMinute)
    }

    /// Change today's window to a specific time. Can be done multiple times from the lock screen.
    /// Used by the lock screen time picker.
    func postponeToTime(hour: Int, minute: Int) {
        guard !hasUsedTodaysWindow else { return }

        postponedHour = hour
        postponedMinute = minute
        hasPostponedToday = true

        // Reset prefetch so it re-triggers for the new window time.
        // If we already prefetched, we only need an incremental scan for the gap.
        let wasPrefetched = hasPrefetchedForWindow
        hasPrefetchedForWindow = false

        if wasPrefetched && !items.isEmpty {
            // Already have items from the earlier prefetch — just scan for anything new
            print("⏰ Window rescheduled after prefetch — will do incremental scan for gap")
            Task {
                await checkForNewItems()
                hasFetchedThisWindow = true
                hasPrefetchedForWindow = true
                print("⏰ Incremental gap scan complete — ledger has \(items.count) items")
            }
        }

        // Cancel current nags
        NotificationManager.shared.cancelAllNags()

        // Schedule new notification at the chosen time
        NotificationManager.shared.schedulePostponedReminder(hour: hour, minute: minute)

        print("⏰ Window time changed to \(hour):\(String(format: "%02d", minute))")
    }

    /// The effective hour/minute for today's window (accounts for postpone)
    var effectiveHour: Int { postponedHour ?? notificationHour }
    var effectiveMinute: Int { postponedMinute ?? notificationMinute }

    // MARK: - Calendar Conflict Actions

    /// User accepted the suggested alternate time — postpone the window
    func acceptConflictSuggestion(_ suggestion: WindowConflictSuggestion) {
        postponeToTime(hour: suggestion.suggestedHour, minute: suggestion.suggestedMinute)
        windowConflict = nil
        NotificationManager.shared.cancelConflictNotification()
        print("📅 User accepted conflict suggestion → moved to \(suggestion.formatSuggestedTime)")
    }

    /// User dismissed the conflict suggestion — keep original time
    func dismissConflictSuggestion() {
        windowConflict = nil
        NotificationManager.shared.cancelConflictNotification()
        // Persist that we dismissed today's conflict so it doesn't reappear
        UserDefaults.standard.set(todayString, forKey: "ledger_conflict_dismissed")
        print("📅 User dismissed conflict suggestion — keeping original time")
    }

    // MARK: - Add Accounts

    func addGmailAccount() async {
        do {
            let result = try await gmailManager.signIn()
            guard !accounts.contains(where: { $0.id == result.email }) else {
                print("⚠️ Gmail account already exists: \(result.email)")
                return
            }
            accounts.append(ConnectedAccount(
                id: result.email, service: .gmail,
                displayName: result.displayName, identifier: result.email,
                accessToken: result.accessToken
            ))
            saveAccounts()
            print("✅ Gmail added: \(result.email) — total accounts: \(accounts.count)")
            await fetchNewAccountItems(accountId: result.email)
        } catch {
            print("❌ Gmail sign-in: \(error.localizedDescription)")
        }
    }

    func addOutlookAccount() async {
        do {
            let result = try await outlookManager.signIn()
            guard !accounts.contains(where: { $0.id == result.email }) else {
                print("⚠️ Outlook account already exists: \(result.email)")
                return
            }
            accounts.append(ConnectedAccount(
                id: result.email, service: .outlook,
                displayName: result.displayName, identifier: result.email,
                accessToken: result.accessToken
            ))
            saveAccounts()
            print("✅ Outlook added: \(result.email) — total accounts: \(accounts.count)")
            await fetchNewAccountItems(accountId: result.email)
        } catch OutlookError.userCancelled {
            // User dismissed the sign-in sheet — not an error
            print("ℹ️ Outlook sign-in cancelled by user")
        } catch {
            print("❌ Outlook sign-in: \(error.localizedDescription)")
        }
    }

    func addSlackAccount() async {
        do {
            let result = try await slackManager.signIn()
            let accountId = "slack_\(result.userId)"
            guard !accounts.contains(where: { $0.id == accountId }) else { return }
            accounts.append(ConnectedAccount(
                id: accountId, service: .slack,
                displayName: result.teamName, identifier: result.teamName,
                accessToken: result.accessToken
            ))
            saveAccounts()
            // NEW: Register with backend (non-blocking)
            let token = result.accessToken
            let team = result.teamName
            let uid = result.userId
            Task.detached {
                do {
                    try await BackendManager.shared.register(
                        provider: "slack", accessToken: token,
                        refreshToken: "", email: "slack_\(uid)@slack",
                        displayName: team, deviceToken: nil
                    )
                    print("✅ Slack registered with backend")
                } catch {
                    print("⚠️ Slack backend reg failed: \(error.localizedDescription)")
                }
            }
            await fetchNewAccountItems(accountId: accountId)
        } catch {
            print("❌ Slack sign-in: \(error.localizedDescription)")
        }
    }

    func addTelegramAccount() async {
        do {
            let result = try await telegramManager.signIn()
            let accountId = "tg_\(result.userId)"
            guard !accounts.contains(where: { $0.id == accountId }) else { return }
            accounts.append(ConnectedAccount(
                id: accountId, service: .telegram,
                displayName: result.displayName, identifier: result.displayName,
                accessToken: result.botToken
            ))
            saveAccounts()
            // NEW: Register with backend (non-blocking)
            let botToken = result.botToken
            let name = result.displayName
            let uid = result.userId
            Task.detached {
                do {
                    try await BackendManager.shared.register(
                        provider: "telegram", accessToken: botToken,
                        refreshToken: "", email: "tg_\(uid)@telegram",
                        displayName: name, deviceToken: nil
                    )
                    print("✅ Telegram registered with backend")
                } catch {
                    print("⚠️ Telegram backend reg failed: \(error.localizedDescription)")
                }
            }
            await fetchNewAccountItems(accountId: accountId)
        } catch {
            print("❌ Telegram sign-in: \(error.localizedDescription)")
        }
    }

    func addGroupMeAccount() async {
        do {
            let result = try await groupMeManager.signIn()
            let accountId = "gm_\(result.userId)"
            guard !accounts.contains(where: { $0.id == accountId }) else { return }
            accounts.append(ConnectedAccount(
                id: accountId, service: .groupme,
                displayName: result.displayName, identifier: result.displayName,
                accessToken: result.accessToken
            ))
            saveAccounts()
            // NEW: Register with backend (non-blocking)
            let gmToken = result.accessToken
            let name = result.displayName
            let uid = result.userId
            Task.detached {
                do {
                    try await BackendManager.shared.register(
                        provider: "groupme", accessToken: gmToken,
                        refreshToken: "", email: "gm_\(uid)@groupme",
                        displayName: name, deviceToken: nil
                    )
                    print("✅ GroupMe registered with backend")
                } catch {
                    print("⚠️ GroupMe backend reg failed: \(error.localizedDescription)")
                }
            }
            await fetchNewAccountItems(accountId: accountId)
        } catch {
            print("❌ GroupMe sign-in: \(error.localizedDescription)")
        }
    }

    /// Teams uses the same Microsoft account as Outlook — reuses MSAL auth
    func addTeamsAccount() async {
        do {
            let result = try await outlookManager.signIn()
            let accountId = "teams_\(result.email)"
            guard !accounts.contains(where: { $0.id == accountId }) else { return }
            accounts.append(ConnectedAccount(
                id: accountId, service: .teams,
                displayName: result.displayName, identifier: result.email,
                accessToken: result.accessToken
            ))
            saveAccounts()
            // NEW: Register with backend (non-blocking)
            let teamsToken = result.accessToken
            let teamsEmail = result.email
            let teamsName = result.displayName
            Task.detached {
                do {
                    try await BackendManager.shared.register(
                        provider: "teams", accessToken: teamsToken,
                        refreshToken: "", email: teamsEmail,
                        displayName: teamsName, deviceToken: nil
                    )
                    print("✅ Teams registered with backend")
                } catch {
                    print("⚠️ Teams backend reg failed: \(error.localizedDescription)")
                }
            }
            await fetchNewAccountItems(accountId: accountId)
        } catch OutlookError.userCancelled {
            print("ℹ️ Teams sign-in cancelled by user")
        } catch {
            print("❌ Teams sign-in: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch from Newly Added Account

    /// If the ledger window is open, fetch items from a newly added account and merge them in.
    private func fetchNewAccountItems(accountId: String) async {
        guard !isLocked, hasFetchedThisWindow else { return }
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }

        isScanningNewAccount = account.service.label
        defer { isScanningNewAccount = nil }

        print("🔄 Fetching from newly added account: \(account.service.label) (\(account.identifier))")

        var fetched: [LedgerEmail] = []
        do {
            switch account.service {
            case .gmail:
                await refreshGmailToken(for: account.id)
                let token = accounts.first(where: { $0.id == account.id })?.accessToken ?? account.accessToken
                fetched = try await gmailManager.fetchRecentUnread(accessToken: token)
            case .outlook:
                await refreshOutlookToken(for: account.id)
                let token = accounts.first(where: { $0.id == account.id })?.accessToken ?? account.accessToken
                fetched = try await outlookManager.fetchRecentUnread(accessToken: token)
            case .teams:
                await refreshOutlookToken(for: account.id)
                let token = accounts.first(where: { $0.id == account.id })?.accessToken ?? account.accessToken
                fetched = try await outlookManager.fetchRecentTeamsChats(accessToken: token)
            case .slack:
                fetched = try await slackManager.fetchRecentMessages(accessToken: account.accessToken)
            case .groupme:
                fetched = try await groupMeManager.fetchRecentMessages(accessToken: account.accessToken)
            case .telegram:
                fetched = try await telegramManager.fetchRecentMessages()
            }
        } catch {
            print("❌ New account fetch: \(error.localizedDescription)")
            return
        }

        // Tag with account ID
        for i in 0..<fetched.count { fetched[i].accountId = account.id }

        // Pre-filter
        let existingIds = Set(items.map { $0.id })
            .union(dismissedIds)
            .union(Set(dismissedItems.map { $0.id }))
            .union(Set(snoozedItems.map { $0.id }))
        fetched = fetched.filter { !existingIds.contains($0.id) }

        guard !fetched.isEmpty else {
            print("✅ New account: no new items to add")
            return
        }

        // AI score the new items
        let batchSize = 5
        for batchStart in stride(from: 0, to: fetched.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, fetched.count)
            let batch = Array(fetched[batchStart..<batchEnd])
            let results = await aiManager.analyzeBatch(emails: batch)
            for (offset, result) in results.enumerated() {
                let i = batchStart + offset
                guard i < fetched.count else { break }
                if let result = result {
                    fetched[i].aiSummary = result.summary
                    fetched[i].suggestedDraft = result.draftResponse
                    fetched[i].detectedTone = result.detectedTone
                    fetched[i].replyability = result.replyability
                    fetched[i].category = result.category
                    fetched[i].suggestReplyAll = result.suggestReplyAll ?? false
                }
            }
        }

        // Filter by replyability threshold and merge
        let qualified = fetched.filter { $0.replyability >= 40 }
        if !qualified.isEmpty {
            items.append(contentsOf: qualified)
            items = deduplicateByThread(items)
            items = LedgerRanker.rank(items)
            print("✅ New account: added \(qualified.count) items to ledger")
        }
    }

    // MARK: - Remove / Toggle Account

    func removeAccount(_ account: ConnectedAccount) {
        switch account.service {
        case .gmail:    gmailManager.signOut()
        case .outlook:  outlookManager.signOut(email: account.identifier)
        case .teams:    outlookManager.signOut(email: account.identifier)
        case .slack:    slackManager.signOut()
        case .telegram: telegramManager.signOut()
        case .groupme:  break // No SDK sign-out needed for GroupMe
        }
        accounts.removeAll { $0.id == account.id }
        items.removeAll { $0.accountId == account.id }
        dismissedItems.removeAll { $0.accountId == account.id }
        saveAccounts()
        if !hasSources {
            hasCompletedOnboarding = false
            UserDefaults.standard.set(false, forKey: "ledger_onboarded")
        }
    }

    func toggleAccount(_ account: ConnectedAccount) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].isEnabled.toggle()
            if !accounts[idx].isEnabled {
                items.removeAll { $0.accountId == account.id }
            }
            saveAccounts()
        }
    }

    func enableIMessage() {
        imessageEnabled = true
        // Dedicated iMessage fetch — don't rely on checkForNewItems/fetchAndProcess
        // which may already be running or have already completed with imessageEnabled=false.
        Task {
            // If the main fetch hasn't happened yet (e.g. iMessage setup during onboarding),
            // trigger a full fetchAndProcess which handles ALL sources including Gmail.
            if !hasFetchedThisWindow {
                print("📱 enableIMessage: triggering full fetchAndProcess (first fetch)")
                await fetchAndProcess()
            }

            // Wait briefly for the Mac relay to start pushing messages
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            await fetchIMessageItems()
            // Retry after 10 more seconds in case relay was slow
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            await fetchIMessageItems()
        }
    }

    /// Standalone iMessage fetch — adds iMessage items to the existing stack.
    /// Used when iMessage is enabled after the initial fetch has already run.
    private func fetchIMessageItems() async {
        guard imessageEnabled else { return }
        print("📱 Fetching iMessage items...")
        do {
            var msgs = try await messageManager.fetchRecentMessages()
            if msgs.isEmpty {
                print("📱 iMessage: 0 messages from relay")
                return
            }

            print("📱 iMessage: fetched \(msgs.count) messages from backend")

            // Filter out any we already have (by message ID)
            let existingIds = Set(items.map { $0.id })
                .union(dismissedIds)
                .union(Set(dismissedItems.map { $0.id }))
            msgs = msgs.filter { !existingIds.contains($0.id) }

            // Filter out dismissed threads — prevents conversations from resurfacing
            // when new messages arrive with different message IDs
            msgs = msgs.filter { !dismissedThreadIds.contains($0.threadId) }

            if msgs.isEmpty {
                print("📱 iMessage: all messages already in stack")
                return
            }

            print("📱 iMessage: \(msgs.count) new messages after dedup")

            // Messages from the backend are already AI-scored.
            // Only score ones that don't have scores yet.
            let unscored = msgs.enumerated().filter { $0.element.aiSummary == nil }
            if !unscored.isEmpty {
                print("📱 iMessage: scoring \(unscored.count) unscored messages")
                isProcessingAI = true
                let unscoredItems = unscored.map { $0.element }
                let batchSize = 5
                for batchStart in stride(from: 0, to: unscoredItems.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, unscoredItems.count)
                    let batch = Array(unscoredItems[batchStart..<batchEnd])
                    let results = await aiManager.analyzeBatch(emails: batch)
                    for (offset, result) in results.enumerated() {
                        let originalIndex = unscored[batchStart + offset].offset
                        guard let result = result else { continue }
                        msgs[originalIndex].aiSummary = result.summary
                        msgs[originalIndex].suggestedDraft = result.draftResponse
                        msgs[originalIndex].detectedTone = result.detectedTone
                        msgs[originalIndex].replyability = result.replyability
                        msgs[originalIndex].category = result.category
                        msgs[originalIndex].suggestReplyAll = result.suggestReplyAll ?? false
                    }
                }
                isProcessingAI = false
            }

            // Filter by replyability — items from backend already passed threshold,
            // but locally scored ones might not
            let qualified = msgs.filter { $0.replyability >= 40 }
            if !qualified.isEmpty {
                print("📱 iMessage: adding \(qualified.count) items to stack")
                items.append(contentsOf: qualified)
                items = deduplicateByThread(items)
                items = LedgerRanker.rank(items)
                saveLedgerState()
            } else {
                print("📱 iMessage: no items passed replyability threshold")
            }
        } catch {
            print("❌ iMessage fetch: \(error.localizedDescription)")
        }
    }

    func disableIMessage() {
        imessageEnabled = false
        items.removeAll { $0.source == .imessage }
        dismissedItems.removeAll { $0.source == .imessage }
        dismissedThreadIds.removeAll()
        UserDefaults.standard.removeObject(forKey: "ledger_dismissed_thread_ids")
        if !hasSources {
            hasCompletedOnboarding = false
            UserDefaults.standard.set(false, forKey: "ledger_onboarded")
        }
    }

    // MARK: - Token Helpers

    func token(for item: LedgerEmail) -> String? {
        accounts.first(where: { $0.id == item.accountId })?.accessToken
    }

    func userEmail(for item: LedgerEmail) -> String {
        accounts.first(where: { $0.id == item.accountId })?.identifier ?? ""
    }

    /// Force-refreshes the Gmail access token for a given account.
    /// Returns the fresh token (or nil if refresh failed).
    @discardableResult
    private func refreshGmailToken(for accountId: String) async -> String? {
        do {
            if let result = try await gmailManager.restoreSession() {
                if let idx = accounts.firstIndex(where: { $0.id == accountId }) {
                    accounts[idx].accessToken = result.accessToken
                    saveAccounts()
                    print("🔄 Gmail token refreshed for \(result.email)")
                    return result.accessToken
                }
            } else {
                print("⚠️ Gmail: no current user session for \(accountId) — user may need to re-sign in")
            }
        } catch {
            print("⚠️ Gmail token refresh failed for \(accountId): \(error.localizedDescription)")
        }
        return nil
    }

    /// Builds a closure that refreshes the Gmail token on demand (for retry-on-401).
    private func gmailTokenRefresher(for accountId: String) -> (() async -> String?) {
        return { [weak self] in
            return await self?.refreshGmailToken(for: accountId)
        }
    }

    /// Force-refreshes the Outlook access token for a given account.
    /// Returns the fresh token (or nil if refresh failed).
    @discardableResult
    private func refreshOutlookToken(for accountId: String) async -> String? {
        let email = accounts.first(where: { $0.id == accountId })?.identifier ?? accountId
        do {
            let newToken = try await outlookManager.refreshToken(for: email)
            if let idx = accounts.firstIndex(where: { $0.id == accountId }) {
                accounts[idx].accessToken = newToken
                saveAccounts()
                print("🔄 Outlook token refreshed for \(email)")
            }
            return newToken
        } catch {
            print("⚠️ Outlook token refresh failed for \(email): \(error.localizedDescription)")
            return nil
        }
    }

    /// Builds a closure that refreshes the Outlook token on demand (for retry-on-401).
    private func outlookTokenRefresher(for accountId: String) -> (() async -> String?) {
        return { [weak self] in
            return await self?.refreshOutlookToken(for: accountId)
        }
    }

    /// Gets the latest valid token for an account, refreshing if needed.
    private func freshToken(for account: ConnectedAccount) async -> String {
        // Always try to refresh first — tokens should never be stale
        switch account.service {
        case .gmail:
            if let fresh = await refreshGmailToken(for: account.id) { return fresh }
        case .outlook, .teams:
            if let fresh = await refreshOutlookToken(for: account.id) { return fresh }
        default:
            break
        }
        // Fallback to stored token if refresh failed
        return accounts.first(where: { $0.id == account.id })?.accessToken ?? account.accessToken
    }

    // MARK: - Fetch & Process

    func fetchAndProcess() async {
        isLoading = true
        defer {
            isLoading = false
            isFirstRunActive = false
        }

        // First-ever run: two-pass — 24h (today) + days 2–7 (earlier this week)
        let isFirstRun = !hasCompletedFirstRun
        let now = Date()
        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!

        if isFirstRun {
            isFirstRunActive = true
            print("📬 FIRST RUN — two-pass: past 24h + days 2–7")
        }

        print("📬 fetchAndProcess started — mode: \(ledgerMode.rawValue), accounts: \(enabledAccounts.count), dismissedIds: \(dismissedIds.count), firstRun: \(isFirstRun)")

        // Refresh calendar API cache if stale (Standard+ only)
        if SubscriptionManager.shared.calendarEnabled && CalendarManager.shared.needsCacheRefresh {
            for account in enabledAccounts {
                _ = await freshToken(for: account)
            }
            await CalendarManager.shared.refreshAPICache()
        }

        // Restore snoozed items from yesterday — check if they still need replies
        let restoredSnoozed = await restoreSnoozedItems()

        // Fetch provider email signatures (once per session)
        if providerSignatures.isEmpty {
            await fetchProviderSignatures()
        }

        var allItems: [LedgerEmail] = []

        // Pass 1: Normal fetch (last 24h, or since last window)
        for account in enabledAccounts {
            do {
                var fetched: [LedgerEmail] = []
                let token = await freshToken(for: account)
                switch account.service {
                case .gmail:
                    fetched = try await gmailManager.fetchRecentUnread(
                        accessToken: token,
                        since: nil,  // uses Date.sinceLastWindow (24h default)
                        maxResults: 40,
                        tokenRefresher: gmailTokenRefresher(for: account.id)
                    )
                case .outlook:
                    fetched = try await outlookManager.fetchRecentUnread(accessToken: token, since: nil)
                case .teams:
                    fetched = try await outlookManager.fetchRecentTeamsChats(accessToken: token, since: nil)
                case .slack:
                    fetched = try await slackManager.fetchRecentMessages(accessToken: token, since: nil)
                case .telegram:
                    fetched = try await telegramManager.fetchRecentMessages()
                case .groupme:
                    fetched = try await groupMeManager.fetchRecentMessages(accessToken: token, since: nil)
                }
                for i in 0..<fetched.count { fetched[i].accountId = account.id }
                print("📬 Pass 1 — \(account.service.label) (\(account.identifier)): fetched \(fetched.count) items")
                allItems.append(contentsOf: fetched)
            } catch {
                print("❌ \(account.service.label) fetch (\(account.identifier)): \(error.localizedDescription)")
            }
        }

        let pass1Ids = Set(allItems.map { $0.id })

        // Pass 2 (first run only): Fetch days 2–7 and tag as "earlier this week"
        var earlierItems: [LedgerEmail] = []
        if isFirstRun {
            for account in enabledAccounts {
                do {
                    var fetched: [LedgerEmail] = []
                    let token = await freshToken(for: account)
                    switch account.service {
                    case .gmail:
                        fetched = try await gmailManager.fetchRecentUnread(
                            accessToken: token,
                            since: sevenDaysAgo,
                            maxResults: 100,
                            tokenRefresher: gmailTokenRefresher(for: account.id)
                        )
                    case .outlook:
                        fetched = try await outlookManager.fetchRecentUnread(accessToken: token, since: sevenDaysAgo)
                    case .teams:
                        fetched = try await outlookManager.fetchRecentTeamsChats(accessToken: token, since: sevenDaysAgo)
                    case .slack:
                        fetched = try await slackManager.fetchRecentMessages(accessToken: token, since: sevenDaysAgo)
                    case .telegram:
                        fetched = try await telegramManager.fetchRecentMessages()
                    case .groupme:
                        fetched = try await groupMeManager.fetchRecentMessages(accessToken: token, since: sevenDaysAgo)
                    }
                    for i in 0..<fetched.count { fetched[i].accountId = account.id }
                    // Only keep items NOT already in pass 1 (deduplicate)
                    fetched = fetched.filter { !pass1Ids.contains($0.id) }
                    // Tag as earlier this week
                    for i in 0..<fetched.count { fetched[i].isEarlierThisWeek = true }
                    print("📬 Pass 2 — \(account.service.label) (\(account.identifier)): \(fetched.count) earlier items")
                    earlierItems.append(contentsOf: fetched)
                } catch {
                    print("❌ Pass 2 \(account.service.label) (\(account.identifier)): \(error.localizedDescription)")
                }
            }
        }

        // Merge pass 2 items after pass 1
        allItems.append(contentsOf: earlierItems)

        if imessageEnabled {
            do {
                let msgs = try await messageManager.fetchRecentMessages()
                allItems.append(contentsOf: msgs)
            } catch {
                print("❌ iMessage fetch: \(error.localizedDescription)")
            }
        }

        isProcessingAI = true

        let fetchedCount = allItems.count
        print("📬 Fetched \(fetchedCount) total items from all sources (pass1: \(pass1Ids.count), earlier: \(earlierItems.count))")

        // Pre-filter: ONLY skip items that are DEFINITIVELY automated/commercial.
        // Philosophy: it's better to show one extra email than miss a human message.
        // The AI layer will handle nuance — pre-filter only removes obvious machine-generated mail.
        let preFilterCount = allItems.count
        allItems = allItems.filter { item in
            // Skip items user already replied to
            if item.userHasReplied {
                print("   ⏭ Skipped (already replied): \(item.senderName) — \(item.subject)")
                return false
            }

            let addr = item.senderEmail.lowercased()
            let subj = item.subject.lowercased()
            let bodySnippet = String(item.body.lowercased().prefix(500))

            // 1. DEFINITIVE no-reply addresses — these are never human
            let noReplyPatterns = ["noreply", "no-reply", "do-not-reply", "donotreply",
                                   "mailer-daemon", "postmaster", "bounces+"]
            if noReplyPatterns.contains(where: { addr.contains($0) }) {
                print("   ⏭ Skipped (no-reply address): \(item.senderName) <\(item.senderEmail)> — \(item.subject)")
                return false
            }

            // 2. DEFINITIVE automated address prefixes — bulk/system senders
            //    Only filter these when they're the prefix (before @), not part of a name
            let automatedPrefixes = ["notifications@", "notification@", "updates@", "newsletter@",
                                     "marketing@", "promo@", "promotions@", "digest@",
                                     "weekly@", "daily@", "monthly@", "automated@", "auto@",
                                     "billing@", "invoice@", "receipts@", "receipt@",
                                     "orders@", "order@", "shipping@", "tracking@",
                                     "nps@", "survey@", "feedback@"]
            if automatedPrefixes.contains(where: { addr.hasPrefix($0.components(separatedBy: "@").first! + "@") || addr.contains($0) }) {
                print("   ⏭ Skipped (automated prefix): \(item.senderName) <\(item.senderEmail)> — \(item.subject)")
                return false
            }

            // 3. DEFINITIVE automated domains — platforms that ONLY send automated mail
            //    (NOT company domains where real humans work like google.com, stripe.com, etc.)
            let automatedOnlyDomains = [
                // Email infrastructure
                "amazonses.com", "mailchimp.com", "sendgrid.net", "mandrillapp.com",
                "mailgun.org", "postmarkapp.com", "constantcontact.com",
                // LinkedIn (all subdomains)
                "linkedin.com", "e.linkedin.com", "email.linkedin.com",
                // Facebook / Meta
                "facebookmail.com", "mail.instagram.com",
                // Twitter / X
                "twitter.com", "x.com", "em.twitter.com", "notify.twitter.com",
                // Other social media
                "pinterest.com", "member.pinterest.com",
                "tiktok.com", "reddit.com", "snapchat.com", "discord.com",
                "nextdoor.com", "tumblr.com",
                // YouTube
                "youtube.com",
                // Ride-share / delivery
                "uber.com", "em.uber.com", "lyft.com",
                "doordash.com", "grubhub.com", "instacart.com", "postmates.com",
                // GitHub
                "github.com", "noreply.github.com",
                // News / media
                "nytimes.com", "washingtonpost.com", "wsj.com", "cnn.com",
                "bbc.com", "bbc.co.uk", "foxnews.com", "nbcnews.com",
                "abcnews.com", "reuters.com", "apnews.com",
                "theguardian.com", "usatoday.com", "bloomberg.com",
                "forbes.com", "businessinsider.com", "techcrunch.com",
                "theverge.com", "wired.com", "arstechnica.com",
                "huffpost.com", "buzzfeed.com", "vox.com",
                "substack.com", "medium.com",
                // Streaming / entertainment
                "spotify.com", "netflix.com", "hulu.com", "disneyplus.com",
                "twitch.tv", "pandora.com",
                // Shopping
                "amazon.com", "ebay.com", "etsy.com", "walmart.com", "target.com",
                "shopify.com",
                // Travel
                "airbnb.com", "booking.com", "expedia.com",
                "tripadvisor.com", "kayak.com",
                // Finance (automated notifications)
                "chase.com", "bankofamerica.com", "wellsfargo.com",
                "capitalone.com", "citi.com", "amex.com",
                "paypal.com", "venmo.com", "cashapp.com",
                // Productivity tools (notification emails)
                "atlassian.com", "jira.com", "asana.com", "trello.com",
                "notion.so", "figma.com", "canva.com", "linear.app",
                "calendly.com", "eventbrite.com", "meetup.com",
                // Cloud / storage
                "dropbox.com", "box.com",
                // CRM / marketing platforms
                "hubspot.com", "salesforce.com", "intercom.io",
                "zendesk.com", "freshdesk.com"
            ]
            let senderDomain = addr.components(separatedBy: "@").last ?? ""
            if automatedOnlyDomains.contains(senderDomain) {
                print("   ⏭ Skipped (automated-only domain): \(item.senderName) <\(item.senderEmail)> — \(item.subject)")
                return false
            }

            // 4. DEFINITIVE subject patterns — things that are NEVER human correspondence
            let definitelyAutomatedSubjects = [
                // Transactional
                "order confirmation", "shipping confirmation",
                "delivery notification", "your receipt from",
                "payment received", "password reset",
                "verify your email", "confirm your email",
                "security alert", "sign-in attempt",
                "two-factor", "2fa code", "verification code",
                "your order has", "track your package",
                "out for delivery", "has been shipped", "has been delivered",
                "your statement is ready", "billing statement",
                "thank you for your purchase", "thank you for your order",
                // LinkedIn
                "wants to connect", "accepted your invitation",
                "new connection", "endorsed you", "viewed your profile",
                "appeared in", "search appearances", "people also viewed",
                "jobs you might be interested", "is hiring",
                "congratulate", "work anniversary", "new job",
                // Social media
                "liked your", "commented on your", "replied to your",
                "mentioned you", "tagged you", "followed you",
                "new follower", "friend request", "poked you",
                "shared a post", "shared a photo", "shared a memory",
                "reacted to your", "retweeted", "new subscriber",
                // News / newsletters / digests
                "daily briefing", "morning briefing", "evening briefing",
                "weekly roundup", "weekly newsletter", "daily newsletter",
                "breaking news", "top stories", "trending now",
                "news alert", "your daily", "your weekly", "your monthly",
                "digest for", "what you missed"
            ]
            if definitelyAutomatedSubjects.contains(where: { subj.contains($0) }) {
                print("   ⏭ Skipped (automated subject): \(item.senderName) — \(item.subject)")
                return false
            }

            // 5. Body: ONLY filter on "do not reply" and "this is an automated message"
            //    DO NOT filter on "unsubscribe" — many real humans send via systems with unsubscribe footers
            let definitelyAutomatedBody = ["do not reply to this email",
                                           "this is an automated message",
                                           "this is a system-generated",
                                           "this message was sent automatically"]
            if definitelyAutomatedBody.contains(where: { bodySnippet.contains($0) }) {
                print("   ⏭ Skipped (automated body): \(item.senderName) — \(item.subject)")
                return false
            }

            return true
        }

        print("📊 Pre-filter: \(preFilterCount) → \(allItems.count) items (\(preFilterCount - allItems.count) filtered out)")

        // Prune expired cache entries
        let cacheExpiry = Date().addingTimeInterval(-scoreCacheMaxAge)
        aiScoreCache = aiScoreCache.filter { $0.value.timestamp > cacheExpiry }

        // Separate items into cached (reuse score) and uncached (need AI scoring)
        var cachedCount = 0
        var itemsNeedingScoring: [(Int, LedgerEmail)] = []  // (index, email)

        for i in 0..<allItems.count {
            if let cached = aiScoreCache[allItems[i].id] {
                // Reuse cached score
                allItems[i].replyability = cached.replyability
                allItems[i].aiSummary = cached.summary
                allItems[i].suggestedDraft = cached.draft
                allItems[i].detectedTone = cached.tone
                allItems[i].category = cached.category
                allItems[i].suggestReplyAll = cached.suggestReplyAll
                cachedCount += 1
                print("   💾 Cache hit: \(allItems[i].senderName) — replyability: \(cached.replyability)")
            } else {
                itemsNeedingScoring.append((i, allItems[i]))
            }
        }

        if cachedCount > 0 {
            print("📊 Score cache: \(cachedCount) cached, \(itemsNeedingScoring.count) need scoring")
        }

        // Score uncached emails in batches
        // First run: score everything (one-time onboarding investment). Normal runs: subscription cap.
        let maxEmails = isFirstRun ? itemsNeedingScoring.count : SubscriptionManager.shared.maxEmailsPerWindow
        let itemsToScore = min(itemsNeedingScoring.count, maxEmails)
        let batchSize = 5

        for batchStart in stride(from: 0, to: itemsToScore, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, itemsToScore)
            let batchEntries = Array(itemsNeedingScoring[batchStart..<batchEnd])
            let batchEmails = batchEntries.map { $0.1 }

            let results = await aiManager.analyzeBatch(emails: batchEmails)

            for (offset, result) in results.enumerated() {
                let originalIndex = batchEntries[offset].0
                guard originalIndex < allItems.count else { break }
                if let result = result {
                    allItems[originalIndex].aiSummary = result.summary
                    allItems[originalIndex].suggestedDraft = result.draftResponse
                    allItems[originalIndex].detectedTone = result.detectedTone
                    allItems[originalIndex].replyability = result.replyability
                    allItems[originalIndex].category = result.category
                    allItems[originalIndex].suggestReplyAll = result.suggestReplyAll ?? false

                    // Cache the score
                    aiScoreCache[allItems[originalIndex].id] = CachedAIScore(
                        replyability: result.replyability,
                        summary: result.summary,
                        draft: result.draftResponse,
                        tone: result.detectedTone,
                        category: result.category,
                        suggestReplyAll: result.suggestReplyAll ?? false,
                        timestamp: Date()
                    )

                    print("   🤖 AI scored \(allItems[originalIndex].senderName) — \"\(allItems[originalIndex].subject)\" → replyability: \(result.replyability), category: \(result.category ?? "?")")
                } else {
                    print("   ⚠️ AI failed for \(allItems[originalIndex].senderName) — \"\(allItems[originalIndex].subject)\"")
                }
            }
        }
        isProcessingAI = false

        allItems = LedgerRanker.rank(allItems)
        let preThresholdCount = allItems.count
        allItems = allItems.filter { $0.replyability >= 40 }
        print("📊 Post-AI: \(preThresholdCount) → \(allItems.count) items (replyability >= 40)")

        // Filter out previously dismissed items (snoozedItems is empty after restore, so no conflict)
        let snoozedIds = Set(snoozedItems.map { $0.id })
        let currentDismissedIds = dismissedIds.union(Set(dismissedItems.map { $0.id })).union(snoozedIds)
        let preDismissCount = allItems.count
        allItems = allItems.filter { item in
            // Filter by message ID (all sources)
            if currentDismissedIds.contains(item.id) { return false }
            // Filter by thread ID (iMessage only) — prevents dismissed conversations
            // from resurfacing when new messages arrive with different message IDs
            if item.source == .imessage && !item.threadId.isEmpty
                && dismissedThreadIds.contains(item.threadId) { return false }
            return true
        }
        print("📊 Dismissed filter: \(preDismissCount) → \(allItems.count) (blocked \(preDismissCount - allItems.count), dismissedIds=\(dismissedIds.count), dismissedThreads=\(dismissedThreadIds.count), snoozedIds=\(snoozedIds.count))")

        // Merge restored snoozed items (from yesterday) — add at the top, avoid duplicates
        if !restoredSnoozed.isEmpty {
            let fetchedIds = Set(allItems.map { $0.id })
            let uniqueSnoozed = restoredSnoozed.filter { !fetchedIds.contains($0.id) }
            allItems.insert(contentsOf: uniqueSnoozed, at: 0)
        }

        // Sort: today's items first (by rank), then earlier this week (by rank)
        let todayItems = allItems.filter { !$0.isEarlierThisWeek }
        let earlierWeekItems = allItems.filter { $0.isEarlierThisWeek }
        allItems = todayItems + earlierWeekItems

        // Deduplicate iMessage threads — only keep newest card per conversation
        allItems = deduplicateByThread(allItems)

        self.items = allItems
        let todayCount = todayItems.count
        let earlierCount = earlierWeekItems.count
        print("✅ Final ledger: \(allItems.count) items to show (today: \(todayCount), earlier: \(earlierCount))")

        // Save timestamp AFTER fetch so next session scans from this point forward
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ledger_last_window_timestamp")

        // Mark first run as done (7-day lookback only happens once, ever)
        if isFirstRun {
            hasCompletedFirstRun = true
            isFirstSession = true
            UserDefaults.standard.set(true, forKey: "ledger_first_run_done")
            print("✅ First run complete — future fetches use normal 24h window")
        }

        // Mark that we've done the initial fetch for this window
        hasFetchedThisWindow = true
        lastFetchTimestamp = Date()

        // Persist ledger to disk so it survives app termination
        saveLedgerState()
    }

    // MARK: - iMessage Thread Deduplication

    /// For iMessage items, only keep the NEWEST card per conversation thread.
    /// When follow-up messages arrive in the same thread, the older card is replaced
    /// by the newer one — each conversation chain = exactly one card.
    /// Additionally, if the user was the last to reply in the conversation (per
    /// conversationContext), the thread is removed entirely — no card needed.
    /// Older replaced card IDs are auto-dismissed so they don't resurface.
    /// Email items are NOT deduplicated (each email has a unique ID).
    private func deduplicateByThread(_ items: [LedgerEmail]) -> [LedgerEmail] {
        var bestByThread: [String: LedgerEmail] = [:]  // threadId → newest item
        var replacedIds: [String] = []  // IDs of older cards that got replaced
        var nonImessageItems: [LedgerEmail] = []

        for item in items {
            if item.source == .imessage && !item.threadId.isEmpty {
                if let existing = bestByThread[item.threadId] {
                    // Keep whichever is newer, dismiss the older one
                    if item.date > existing.date {
                        replacedIds.append(existing.id)
                        bestByThread[item.threadId] = item
                    } else {
                        replacedIds.append(item.id)
                    }
                } else {
                    bestByThread[item.threadId] = item
                }
            } else {
                nonImessageItems.append(item)
            }
        }

        // Remove threads where the user was the last to reply
        var userRepliedThreads: [String] = []
        for (threadId, item) in bestByThread {
            if userWasLastToReply(item) {
                userRepliedThreads.append(threadId)
                replacedIds.append(item.id)
            }
        }
        for threadId in userRepliedThreads {
            bestByThread.removeValue(forKey: threadId)
        }

        // Auto-dismiss replaced older cards so they don't come back
        if !replacedIds.isEmpty {
            dismissedIds.formUnion(replacedIds)
            print("📱 iMessage dedup: kept \(bestByThread.count) threads, auto-dismissed \(replacedIds.count) older cards (user-replied: \(userRepliedThreads.count))")
        }

        // Rebuild: non-iMessage items + one card per iMessage thread
        return nonImessageItems + Array(bestByThread.values).sorted { $0.date > $1.date }
    }

    /// Check if the user was the last person to message in this conversation.
    /// Parses the conversationContext JSON attached to the LedgerEmail.
    private func userWasLastToReply(_ item: LedgerEmail) -> Bool {
        guard let ctxJSON = item.conversationContext,
              let data = ctxJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let lastMsg = arr.last,
              let isFromMe = lastMsg["isFromMe"] as? Bool else {
            return false
        }
        return isFromMe
    }

    // MARK: - Check for New Items (incremental scan)

    /// Only checks for NEW items that arrived since the last fetch.
    /// Does NOT re-scan or re-rank existing items. Used by "Check again" button.
    func checkForNewItems() async {
        // Only do a full re-fetch if we've never fetched this session
        if lastFetchTimestamp == nil {
            print("🔍 Check again: no previous fetch this session, doing full fetchAndProcess")
            hasFetchedThisWindow = false
            await fetchAndProcess()
            return
        }

        let since = lastFetchTimestamp!

        isLoading = true
        defer { isLoading = false }

        // Scan a few seconds before lastFetchTimestamp to avoid edge cases
        let scanSince = since.addingTimeInterval(-30)
        let existingIds = Set(items.map { $0.id })
            .union(dismissedIds)
            .union(Set(dismissedItems.map { $0.id }))
            .union(Set(snoozedItems.map { $0.id }))

        var newItems: [LedgerEmail] = []

        print("🔍 Check again: scanning since \(scanSince), existingIds=\(existingIds.count)")

        for account in enabledAccounts {
            do {
                var fetched: [LedgerEmail] = []
                let token = await freshToken(for: account)
                switch account.service {
                case .gmail:
                    fetched = try await gmailManager.fetchRecentUnread(
                        accessToken: token,
                        since: scanSince,
                        tokenRefresher: gmailTokenRefresher(for: account.id)
                    )
                case .outlook:
                    fetched = try await outlookManager.fetchRecentUnread(accessToken: token, since: scanSince)
                case .teams:
                    fetched = try await outlookManager.fetchRecentTeamsChats(accessToken: token, since: scanSince)
                case .slack:
                    fetched = try await slackManager.fetchRecentMessages(accessToken: token, since: scanSince)
                case .telegram:
                    continue
                case .groupme:
                    fetched = try await groupMeManager.fetchRecentMessages(accessToken: token, since: scanSince)
                }
                // Tag with account info
                fetched = fetched.map { var e = $0; e.accountId = account.id; return e }
                print("🔍 Check again: \(account.service.label) returned \(fetched.count) messages (userHasReplied: \(fetched.filter { $0.userHasReplied }.count))")
                newItems.append(contentsOf: fetched)
            } catch {
                print("❌ Check again fetch: \(error.localizedDescription)")
            }
        }

        // Filter out items we already have or dismissed
        newItems = newItems.filter { !existingIds.contains($0.id) }

        // Also check iMessage if enabled
        if imessageEnabled {
            do {
                let msgs = try await messageManager.fetchRecentMessages()
                let newMsgs = msgs.filter {
                    !existingIds.contains($0.id) && !dismissedThreadIds.contains($0.threadId)
                }
                if !newMsgs.isEmpty {
                    print("🔍 Check again: iMessage returned \(newMsgs.count) new messages")
                    newItems.append(contentsOf: newMsgs)
                }
            } catch {
                print("❌ Check again iMessage: \(error.localizedDescription)")
            }
        }

        if newItems.isEmpty {
            print("✅ Check again: no new items")
            lastFetchTimestamp = Date()
            return
        }

        print("🔍 Check again: \(newItems.count) new items to evaluate")

        // Run through the same pre-filter
        newItems = newItems.filter { item in
            if item.userHasReplied { return false }

            let addr = item.senderEmail.lowercased()
            let subj = item.subject.lowercased()
            let bodySnippet = String(item.body.lowercased().prefix(500))

            let noReplyPatterns = ["noreply", "no-reply", "do-not-reply", "donotreply",
                                   "mailer-daemon", "postmaster", "bounces+"]
            if noReplyPatterns.contains(where: { addr.contains($0) }) { return false }

            let automatedPrefixes = ["notifications@", "notification@", "updates@", "newsletter@",
                                     "marketing@", "promo@", "promotions@", "digest@",
                                     "weekly@", "daily@", "monthly@", "automated@", "auto@",
                                     "billing@", "invoice@", "receipts@", "receipt@",
                                     "orders@", "order@", "shipping@", "tracking@",
                                     "nps@", "survey@", "feedback@"]
            if automatedPrefixes.contains(where: { addr.contains($0) }) { return false }

            let senderDomain = addr.components(separatedBy: "@").last ?? ""
            let automatedOnlyDomains = [
                "linkedin.com", "e.linkedin.com", "email.linkedin.com",
                "facebookmail.com", "mail.instagram.com",
                "twitter.com", "x.com", "em.twitter.com",
                "pinterest.com", "tiktok.com", "reddit.com", "snapchat.com", "discord.com",
                "youtube.com", "github.com", "noreply.github.com",
                "amazonses.com", "mailchimp.com", "sendgrid.net", "mandrillapp.com",
                "mailgun.org", "postmarkapp.com",
                "nytimes.com", "washingtonpost.com", "wsj.com", "cnn.com",
                "bbc.com", "bbc.co.uk", "reuters.com", "apnews.com",
                "bloomberg.com", "forbes.com", "substack.com", "medium.com",
                "spotify.com", "netflix.com", "uber.com", "doordash.com",
                "amazon.com", "ebay.com", "shopify.com",
                "chase.com", "bankofamerica.com", "wellsfargo.com",
                "paypal.com", "venmo.com",
                "atlassian.com", "asana.com", "trello.com", "notion.so",
                "hubspot.com", "salesforce.com", "zendesk.com"
            ]
            if automatedOnlyDomains.contains(senderDomain) { return false }

            let definitelyAutomatedSubjects = [
                "order confirmation", "shipping confirmation", "password reset",
                "verify your email", "security alert", "sign-in attempt",
                "two-factor", "2fa code", "wants to connect", "endorsed you",
                "liked your", "commented on your", "followed you",
                "daily briefing", "breaking news", "top stories",
                "has been shipped", "has been delivered",
                "thank you for your purchase"
            ]
            if definitelyAutomatedSubjects.contains(where: { subj.contains($0) }) { return false }

            let definitelyAutomatedBody = ["do not reply to this email",
                                           "this is an automated message",
                                           "this is a system-generated",
                                           "this message was sent automatically"]
            if definitelyAutomatedBody.contains(where: { bodySnippet.contains($0) }) { return false }

            return true
        }

        if newItems.isEmpty {
            print("✅ Check again: new items filtered out by pre-filter")
            lastFetchTimestamp = Date()
            return
        }

        // AI-score only the new items (batched)
        isProcessingAI = true
        let checkBatchSize = 5
        for batchStart in stride(from: 0, to: newItems.count, by: checkBatchSize) {
            let batchEnd = min(batchStart + checkBatchSize, newItems.count)
            let batchEmails = Array(newItems[batchStart..<batchEnd])
            let results = await aiManager.analyzeBatch(emails: batchEmails)
            for (offset, result) in results.enumerated() {
                let i = batchStart + offset
                guard i < newItems.count, let result = result else { continue }
                newItems[i].aiSummary = result.summary
                newItems[i].suggestedDraft = result.draftResponse
                newItems[i].detectedTone = result.detectedTone
                newItems[i].replyability = result.replyability
                newItems[i].category = result.category
                newItems[i].suggestReplyAll = result.suggestReplyAll ?? false
            }
        }
        isProcessingAI = false

        // Only keep items that pass the threshold
        newItems = newItems.filter { $0.replyability >= 40 }

        if !newItems.isEmpty {
            print("🆕 Check again: adding \(newItems.count) new items to ledger")
            items.append(contentsOf: newItems)
            items = deduplicateByThread(items)
            items = LedgerRanker.rank(items)
        } else {
            print("✅ Check again: no new items passed AI filter")
        }

        lastFetchTimestamp = Date()
        saveLedgerState()
    }

    // MARK: - Send

    func sendReply(for item: LedgerEmail, body: String, replyAll: Bool = false) async -> Bool {
        switch item.source {
        case .gmail:
            guard let account = accounts.first(where: { $0.id == item.accountId }) else { return false }
            let token = await freshToken(for: account)
            guard !token.isEmpty else { return false }
            let user = userEmail(for: item)
            let fromName = account.displayName
            let fromEmail = account.identifier
            do {
                if replyAll && item.isMultiRecipient {
                    let r = item.replyAllRecipients(excludingUser: user)
                    try await gmailManager.sendReplyAll(
                        accessToken: token, fromName: fromName, fromEmail: fromEmail,
                        to: r.to, cc: r.cc,
                        subject: "Re: \(item.subject)", body: body,
                        threadId: item.threadId, messageId: item.messageId
                    )
                } else {
                    try await gmailManager.sendReply(
                        accessToken: token, fromName: fromName, fromEmail: fromEmail,
                        to: item.senderEmail,
                        subject: "Re: \(item.subject)", body: body,
                        threadId: item.threadId, messageId: item.messageId
                    )
                }
                if markAsReadAfterReply {
                    try? await gmailManager.markAsRead(messageId: item.id, accessToken: token)
                }
                items.removeAll { $0.id == item.id }; return true
            } catch { print("❌ Gmail send: \(error.localizedDescription)"); return false }

        case .outlook:
            guard let account = accounts.first(where: { $0.id == item.accountId }) else { return false }
            let token = await freshToken(for: account)
            guard !token.isEmpty else { return false }
            do {
                if replyAll && item.isMultiRecipient {
                    try await outlookManager.sendReplyAll(accessToken: token, messageId: item.id, body: body)
                } else {
                    try await outlookManager.sendReply(accessToken: token, messageId: item.id, body: body)
                }
                if markAsReadAfterReply {
                    try? await outlookManager.markAsRead(messageId: item.id, accessToken: token)
                }
                items.removeAll { $0.id == item.id }; return true
            } catch { print("❌ Outlook send: \(error.localizedDescription)"); return false }

        case .teams:
            guard let account = accounts.first(where: { $0.id == item.accountId }) else { return false }
            let token = await freshToken(for: account)
            guard !token.isEmpty else { return false }
            do {
                try await outlookManager.sendTeamsChatMessage(accessToken: token, chatId: item.threadId, text: body)
                items.removeAll { $0.id == item.id }; return true
            } catch { print("❌ Teams send: \(error.localizedDescription)"); return false }

        case .slack:
            guard let token = token(for: item) else { return false }
            do {
                try await slackManager.sendReply(accessToken: token, channelId: item.threadId, threadTs: item.messageId, text: body)
                items.removeAll { $0.id == item.id }; return true
            } catch { print("❌ Slack send: \(error.localizedDescription)"); return false }

        case .telegram:
            do {
                try await telegramManager.sendReply(chatId: item.threadId, replyToMessageId: item.messageId, text: body)
                items.removeAll { $0.id == item.id }; return true
            } catch { print("❌ Telegram send: \(error.localizedDescription)"); return false }

        case .imessage:
            items.removeAll { $0.id == item.id }; return true

        case .groupme:
            guard let token = token(for: item) else { return false }
            do {
                if item.isMultiRecipient {
                    // Group message — threadId is groupId
                    try await groupMeManager.sendGroupMessage(accessToken: token, groupId: item.threadId, text: body)
                } else {
                    // DM — threadId is recipientId
                    try await groupMeManager.sendDirectMessage(accessToken: token, recipientId: item.threadId, text: body)
                }
                items.removeAll { $0.id == item.id }; return true
            } catch { print("❌ GroupMe send: \(error.localizedDescription)"); return false }
        }
    }

    // MARK: - Draft Persistence

    /// Updates the stored draft for an email in the items array.
    /// Called when the user edits the draft in DraftEditorView.
    func updateDraft(for emailId: String, body: String) {
        if let index = items.firstIndex(where: { $0.id == emailId }) {
            items[index].suggestedDraft = body
            saveLedgerState()
        }
    }

    // MARK: - Undo Send (Delayed Dispatch)

    /// Queue a reply for sending after a delay. The card is removed from the stack immediately,
    /// but the actual API call is deferred for `undoSendWindow` seconds.
    /// During that window, the user can tap "Undo" to cancel the send and restore the card.
    func queueSend(for item: LedgerEmail, body: String, replyAll: Bool) {
        // If there's already a pending send, flush it immediately (send it now)
        if pendingSend != nil {
            flushPendingSend()
        }

        // Remove card from stack
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            items.removeAll { $0.id == item.id }
        }

        // Queue the send
        pendingSend = PendingSendItem(
            email: item,
            body: body,
            replyAll: replyAll,
            queuedAt: Date(),
            contactName: item.senderName
        )
        pendingSendCountdown = undoSendWindow

        // Start countdown timer
        pendingSendTimer?.invalidate()
        pendingSendTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.pendingSendCountdown -= 1
                if self.pendingSendCountdown <= 0 {
                    self.flushPendingSend()
                }
            }
        }

        print("📤 Send queued for \(item.senderName) — \(undoSendWindow)s undo window")
        saveLedgerState()
    }

    /// Cancel the pending send, restore the card to the stack with the sent draft text
    func undoSend() {
        pendingSendTimer?.invalidate()
        pendingSendTimer = nil

        guard let pending = pendingSend else { return }
        pendingSend = nil
        pendingSendCountdown = 0

        // Restore the card with the body that was about to be sent
        // (not the original AI suggestion — the user may have edited it)
        var restoredEmail = pending.email
        restoredEmail.suggestedDraft = pending.body

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            items.insert(restoredEmail, at: 0)
        }

        print("↩️ Send cancelled for \(pending.contactName) — card restored with edited draft")
        saveLedgerState()
    }

    /// Actually send the pending reply (called when timer expires or when a new send is queued)
    private func flushPendingSend() {
        pendingSendTimer?.invalidate()
        pendingSendTimer = nil

        guard let pending = pendingSend else { return }
        pendingSend = nil
        pendingSendCountdown = 0

        // Record the reply for stats/style learning BEFORE the async send
        recordSessionReply(contactName: pending.contactName)
        checkLedgerCleared()

        // Fire the actual send asynchronously
        Task {
            let ok = await sendReply(for: pending.email, body: pending.body, replyAll: pending.replyAll)
            if ok {
                print("✅ Delayed send completed for \(pending.contactName)")
            } else {
                print("❌ Delayed send failed for \(pending.contactName) — restoring card")
                // Send failed — restore the card
                await MainActor.run {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        items.insert(pending.email, at: 0)
                    }
                    saveLedgerState()
                }
            }
        }
    }

    // MARK: - Ledger Cleared Check

    /// Whether the ledger was cleared this session (for sending congrats on background)
    var ledgerWasCleared: Bool = false
    /// Names of people replied to this session (for stats)
    var sessionReplyContacts: [String] = []
    var sessionReplyCount: Int = 0

    func recordSessionReply(contactName: String) {
        sessionReplyCount += 1
        if !contactName.isEmpty && !sessionReplyContacts.contains(contactName) {
            sessionReplyContacts.append(contactName)
        }
        LedgerStats.shared.recordReply()
    }

    func checkLedgerCleared() {
        guard items.isEmpty, hasFetchedThisWindow else { return }
        // Cancel nags immediately, but don't send the congrats notification yet —
        // it will be sent when the user backgrounds the app
        NotificationManager.shared.cancelAllNags()
        ledgerWasCleared = true

        // Record session stats for the lock screen
        LedgerStats.shared.recordClearedSession(
            repliesSent: sessionReplyCount,
            contactNames: sessionReplyContacts
        )
    }

    // MARK: - Dismiss

    func dismiss(item: LedgerEmail) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if let removed = items.first(where: { $0.id == item.id }) {
                dismissedItems.insert(removed, at: 0)
                items.removeAll { $0.id == item.id }

                // For iMessage: also track dismissed threadId so new messages
                // in the same conversation don't resurface the card.
                if item.source == .imessage && !item.threadId.isEmpty {
                    dismissedThreadIds.insert(item.threadId)
                    saveDismissedThreadIds()
                }

                // In stack mode, dismissals expire after 24 hours so follow-ups resurface.
                // In window mode, dismissals persist until the next window (traditional behavior).
                if ledgerMode == .stack {
                    saveDismissedWithTimestamp(id: item.id)
                }
                saveDismissedIds()
                checkLedgerCleared()
                saveLedgerState()
            }
        }
    }

    /// Mark a card as "already replied" — user confirmed they handled it outside the app.
    /// This is stronger than dismiss: it tracks the thread permanently and won't resurface
    /// even when the Mac relay eventually syncs.
    func markAsReplied(item: LedgerEmail) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            // Remove from the visible stack (no undo — they confirmed they replied)
            items.removeAll { $0.id == item.id }

            // Track the thread so it never comes back
            if !item.threadId.isEmpty {
                dismissedThreadIds.insert(item.threadId)
                saveDismissedThreadIds()
            }
            dismissedIds.insert(item.id)
            saveDismissedIds()
            checkLedgerCleared()
            saveLedgerState()
        }
    }

    func undoDismiss() {
        guard let restored = dismissedItems.first else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            dismissedItems.removeFirst()
            items.insert(restored, at: 0)
            // Un-dismiss the thread so iMessage cards can appear again
            if restored.source == .imessage && !restored.threadId.isEmpty {
                dismissedThreadIds.remove(restored.threadId)
                saveDismissedThreadIds()
            }
            removeDismissedTimestamp(id: restored.id)
            saveDismissedIds()
            saveLedgerState()
        }
    }

    func restore(item: LedgerEmail) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            dismissedItems.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            // Un-dismiss the thread so iMessage cards can appear again
            if item.source == .imessage && !item.threadId.isEmpty {
                dismissedThreadIds.remove(item.threadId)
                saveDismissedThreadIds()
            }
            removeDismissedTimestamp(id: item.id)
            saveDismissedIds()
            saveLedgerState()
        }
    }

    // MARK: - Dismissed Persistence

    private func saveDismissedIds() {
        let ids = dismissedItems.map { $0.id }
        dismissedIds = Set(ids)
        UserDefaults.standard.set(ids, forKey: "ledger_dismissed_ids")
    }

    func loadDismissedIds() {
        guard let ids = UserDefaults.standard.array(forKey: "ledger_dismissed_ids") as? [String] else { return }
        dismissedIds = Set(ids)
        // In stack mode, prune expired dismissals (older than 24 hours)
        // Also clear any legacy dismissals that have no timestamp
        if ledgerMode == .stack {
            pruneExpiredDismissals()
        }
    }

    /// Clears all dismissed items (e.g. start fresh)
    func clearDismissed() {
        dismissedItems.removeAll()
        dismissedIds.removeAll()
        dismissedThreadIds.removeAll()
        UserDefaults.standard.removeObject(forKey: "ledger_dismissed_ids")
        UserDefaults.standard.removeObject(forKey: "ledger_dismissed_timestamps")
        UserDefaults.standard.removeObject(forKey: "ledger_dismissed_thread_ids")
    }

    private func saveDismissedThreadIds() {
        UserDefaults.standard.set(Array(dismissedThreadIds), forKey: "ledger_dismissed_thread_ids")
    }

    func loadDismissedThreadIds() {
        guard let ids = UserDefaults.standard.array(forKey: "ledger_dismissed_thread_ids") as? [String] else { return }
        dismissedThreadIds = Set(ids)
    }

    // MARK: - Stack Mode Dismissal Expiry

    /// Saves a timestamp for when this item was dismissed (stack mode only)
    private func saveDismissedWithTimestamp(id: String) {
        var timestamps = UserDefaults.standard.dictionary(forKey: "ledger_dismissed_timestamps") as? [String: Double] ?? [:]
        timestamps[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(timestamps, forKey: "ledger_dismissed_timestamps")
    }

    private func removeDismissedTimestamp(id: String) {
        var timestamps = UserDefaults.standard.dictionary(forKey: "ledger_dismissed_timestamps") as? [String: Double] ?? [:]
        timestamps.removeValue(forKey: id)
        UserDefaults.standard.set(timestamps, forKey: "ledger_dismissed_timestamps")
    }

    /// In stack mode, dismissed items stay dismissed FOREVER (never re-surface).
    /// The graveyard (dismissedItems array) keeps them recoverable for 24 hours,
    /// after which they drop out of the graveyard but remain in dismissedIds.
    /// Legacy dismissals with no timestamp are also kept (they're legitimately dismissed).
    private func pruneExpiredDismissals() {
        let timestamps = UserDefaults.standard.dictionary(forKey: "ledger_dismissed_timestamps") as? [String: Double] ?? [:]
        let cutoff = Date().timeIntervalSince1970 - (24 * 60 * 60)

        // Remove items older than 24h from the recoverable graveyard,
        // but keep their IDs in dismissedIds so they never re-surface
        var graveyardPruned = 0
        dismissedItems.removeAll { item in
            if let ts = timestamps[item.id], ts < cutoff {
                graveyardPruned += 1
                return true
            }
            return false
        }

        // Clean up timestamps for items older than 24h (save memory)
        var updatedTimestamps = timestamps
        for (id, ts) in timestamps {
            if ts < cutoff {
                updatedTimestamps.removeValue(forKey: id)
            }
        }
        UserDefaults.standard.set(updatedTimestamps, forKey: "ledger_dismissed_timestamps")

        if graveyardPruned > 0 {
            print("🧹 Removed \(graveyardPruned) items from recovery graveyard (>24h)")
        }
    }

    // MARK: - Ledger State Persistence
    // Saves items, snoozedItems, and dismissedItems to a JSON file
    // so the ledger survives app termination / crashes.

    private var ledgerStatePath: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("ledger_state.json")
    }

    private struct PersistedLedgerState: Codable {
        let items: [LedgerEmail]
        let snoozedItems: [LedgerEmail]
        let dismissedItems: [LedgerEmail]
        let savedAt: Date
        let mode: String  // "stack" or "window"
    }

    /// Save current ledger state to disk. Called after any mutation (fetch, dismiss, snooze, undo).
    func saveLedgerState() {
        // Capture state snapshot on main thread, write to disk on background
        let state = PersistedLedgerState(
            items: items,
            snoozedItems: snoozedItems,
            dismissedItems: dismissedItems,
            savedAt: Date(),
            mode: ledgerMode.rawValue
        )
        let path = ledgerStatePath
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(state)
                try data.write(to: path, options: .atomic)
                print("💾 Ledger state saved — \(state.items.count) items, \(state.snoozedItems.count) snoozed, \(state.dismissedItems.count) dismissed")
            } catch {
                print("⚠️ Failed to save ledger state: \(error.localizedDescription)")
            }
        }
    }

    /// Attempt to restore ledger state from disk. Returns true if state was restored.
    /// Called on app launch before triggering a fetch.
    @discardableResult
    func restoreLedgerState() -> Bool {
        guard FileManager.default.fileExists(atPath: ledgerStatePath.path) else { return false }

        do {
            let data = try Data(contentsOf: ledgerStatePath)
            let state = try JSONDecoder().decode(PersistedLedgerState.self, from: data)

            // Don't restore if the state is from a different mode (user switched)
            guard state.mode == ledgerMode.rawValue else {
                print("💾 Skipping restore — saved mode (\(state.mode)) ≠ current mode (\(ledgerMode.rawValue))")
                clearLedgerState()
                return false
            }

            // Don't restore if the state is older than 24 hours (stale)
            let age = Date().timeIntervalSince(state.savedAt)
            guard age < 24 * 60 * 60 else {
                print("💾 Skipping restore — state is \(Int(age / 3600))h old (>24h)")
                clearLedgerState()
                return false
            }

            // For window mode: don't restore if we're outside the window
            // (state from last night shouldn't appear on tomorrow's lock screen)
            if ledgerMode == .window && !isUnlocked && !hasUsedTodaysWindow {
                print("💾 Skipping restore — window mode, waiting for new window")
                return false
            }

            items = deduplicateByThread(state.items)
            snoozedItems = state.snoozedItems
            dismissedItems = state.dismissedItems
            dismissedIds = Set(state.dismissedItems.map { $0.id })
            // Restore dismissed thread IDs from dismissed iMessage items
            dismissedThreadIds = Set(
                state.dismissedItems
                    .filter { $0.source == .imessage && !$0.threadId.isEmpty }
                    .map { $0.threadId }
            )
            // Also merge any persisted thread IDs (covers threads dismissed in prior sessions)
            loadDismissedThreadIds()
            hasFetchedThisWindow = !items.isEmpty
            lastFetchTimestamp = state.savedAt

            print("💾 Ledger state restored — \(items.count) items, \(snoozedItems.count) snoozed, \(dismissedItems.count) dismissed (saved \(Int(age / 60))min ago)")
            return true
        } catch {
            print("⚠️ Failed to restore ledger state: \(error.localizedDescription)")
            clearLedgerState()
            return false
        }
    }

    /// Delete the persisted state file
    func clearLedgerState() {
        try? FileManager.default.removeItem(at: ledgerStatePath)
    }

    // MARK: - Snooze

    func snooze(item: LedgerEmail) {
        snooze(item: item, hours: snoozeHours)
    }

    func saveSnoozeHours() {
        UserDefaults.standard.set(snoozeHours, forKey: "ledger_snooze_hours")
        Task { await BackendManager.shared.syncSettings(.init(
            mode: nil, windowHour: nil, windowMinute: nil,
            sensitivity: nil, snoozeHours: snoozeHours, scoreThreshold: nil, scanIntervalMinutes: nil
        )) }
    }

    /// Human-readable snooze label for UI (e.g. "4 hours", "tomorrow", "2 days")
    var snoozeLabel: String {
        switch snoozeHours {
        case 1:       return "1 hour"
        case 2...11:  return "\(snoozeHours) hours"
        case 12:      return "12 hours"
        case 24:      return "tomorrow"
        default:      return "\(snoozeHours) hours"
        }
    }

    /// Snooze with a specific delay in hours.
    /// Default: 24 hours in both modes. The email re-enters the ledger after the delay.
    func snooze(item: LedgerEmail, hours: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if let removed = items.first(where: { $0.id == item.id }) {
                snoozedItems.append(removed)
                items.removeAll { $0.id == item.id }

                // Save snooze-until timestamp
                let snoozeUntil = Date().addingTimeInterval(Double(hours) * 3600)
                saveSnoozedWithTimestamp(id: item.id, until: snoozeUntil)
                saveSnoozedIds()
                checkLedgerCleared()
                saveLedgerState()
            }
        }
    }

    func restoreSnoozedItems() async -> [LedgerEmail] {
        loadSnoozedIds()
        guard !snoozedItems.isEmpty else { return [] }

        let now = Date()
        let snoozedTimestamps = UserDefaults.standard.dictionary(forKey: "ledger_snoozed_until") as? [String: Double] ?? [:]

        var readyToRestore: [LedgerEmail] = []
        var stillSnoozed: [LedgerEmail] = []

        for item in snoozedItems {
            // Check if snooze has expired
            if let snoozeUntil = snoozedTimestamps[item.id] {
                if now.timeIntervalSince1970 >= snoozeUntil {
                    // Snooze expired — check if still unread before restoring
                    var shouldRestore = true
                    if let account = accounts.first(where: { $0.id == item.accountId }) {
                        let tok = await freshToken(for: account)
                        switch item.source {
                        case .gmail:
                            shouldRestore = await gmailManager.isMessageStillUnread(accessToken: tok, messageId: item.id)
                        case .outlook:
                            shouldRestore = await outlookManager.isMessageStillUnread(accessToken: tok, messageId: item.id)
                        default:
                            break
                        }
                    }
                    if shouldRestore {
                        readyToRestore.append(item)
                    }
                } else {
                    stillSnoozed.append(item)
                }
            } else {
                // No timestamp — legacy snooze, restore it
                readyToRestore.append(item)
            }
        }

        snoozedItems = stillSnoozed
        saveSnoozedIds()

        var updatedTimestamps = snoozedTimestamps
        for item in readyToRestore {
            updatedTimestamps.removeValue(forKey: item.id)
        }
        UserDefaults.standard.set(updatedTimestamps, forKey: "ledger_snoozed_until")

        if !readyToRestore.isEmpty {
            print("⏰ Restored \(readyToRestore.count) snoozed items (snooze expired)")
        }

        return readyToRestore
    }

    // MARK: - Snooze Persistence

    private func saveSnoozedWithTimestamp(id: String, until: Date) {
        var timestamps = UserDefaults.standard.dictionary(forKey: "ledger_snoozed_until") as? [String: Double] ?? [:]
        timestamps[id] = until.timeIntervalSince1970
        UserDefaults.standard.set(timestamps, forKey: "ledger_snoozed_until")
    }

    private func saveSnoozedIds() {
        let encoded = snoozedItems.map { item -> [String: String] in
            ["id": item.id, "source": item.source.rawValue, "accountId": item.accountId,
             "threadId": item.threadId, "messageId": item.messageId,
             "senderName": item.senderName, "senderEmail": item.senderEmail,
             "subject": item.subject, "snippet": item.snippet,
             "body": String(item.body.prefix(500)),
             "date": ISO8601DateFormatter().string(from: item.date)]
        }
        UserDefaults.standard.set(encoded, forKey: "ledger_snoozed")
    }

    private func loadSnoozedIds() {
        guard let saved = UserDefaults.standard.array(forKey: "ledger_snoozed") as? [[String: String]] else { return }
        let formatter = ISO8601DateFormatter()
        snoozedItems = saved.compactMap { dict -> LedgerEmail? in
            guard let id = dict["id"],
                  let sourceStr = dict["source"],
                  let source = LedgerSource(rawValue: sourceStr),
                  let senderName = dict["senderName"],
                  let senderEmail = dict["senderEmail"] else { return nil }
            var item = LedgerEmail(
                id: id, source: source,
                threadId: dict["threadId"] ?? "", messageId: dict["messageId"] ?? "",
                senderName: senderName, senderEmail: senderEmail,
                subject: dict["subject"] ?? "", snippet: dict["snippet"] ?? "",
                body: dict["body"] ?? "",
                date: formatter.date(from: dict["date"] ?? "") ?? Date(),
                isUnread: true
            )
            item.accountId = dict["accountId"] ?? ""
            return item
        }
    }

    // Legacy shims
    var emails: [LedgerEmail] { items }
    var isSignedIn: Bool { isReady }
    var isLoadingEmails: Bool { isLoading }
    var isGmailSignedIn: Bool { accounts.contains { $0.service == .gmail } }
    var isOutlookSignedIn: Bool { accounts.contains { $0.service == .outlook } }
    var isSlackSignedIn: Bool { accounts.contains { $0.service == .slack } }
    var isTelegramSignedIn: Bool { accounts.contains { $0.service == .telegram } }
    var userEmail: String { accounts.first(where: { $0.service == .gmail })?.identifier ?? "" }
    var accessToken: String? { accounts.first(where: { $0.service == .gmail })?.accessToken }

    func signInGmail() async { await addGmailAccount() }
    func signInOutlook() async { await addOutlookAccount() }
    func signInSlack() async { await addSlackAccount() }
    func signInTelegram() async { await addTelegramAccount() }
    func signInTeams() async { await addTeamsAccount() }
    func signOutGmail() { accounts.filter { $0.service == .gmail }.forEach { removeAccount($0) } }
    func signOut() { signOutGmail() }
    func fetchAndProcessEmails() async { await fetchAndProcess() }
    func dismiss(email: LedgerEmail) { dismiss(item: email) }
}

// MARK: - Ranking Engine

enum LedgerRanker {
    static func rank(_ items: [LedgerEmail]) -> [LedgerEmail] {
        let now = Date()
        let scored = items.map { item -> (LedgerEmail, Double) in
            let replyScore = Double(item.replyability)

            // Already replied = done
            if item.userHasReplied { return (item, 0) }

            // Trust the AI score — if AI said 40+, it detected a human
            // Only zero out if AI itself scored 0
            if replyScore == 0 { return (item, 0) }

            let hoursAgo = max(0.1, now.timeIntervalSince(item.date) / 3600)
            let recencyBonus = min(24.0, 24.0 / hoursAgo)

            // Unread gets a boost — but read items still rank
            let unreadBonus: Double = item.isUnread ? 10.0 : 0.0

            let sourceBonus: Double
            switch item.source {
            case .imessage, .telegram: sourceBonus = 8.0
            case .slack, .teams, .groupme: sourceBonus = 5.0
            case .gmail, .outlook: sourceBonus = 0.0
            }

            // Light category penalties — nudge, don't override AI judgment
            let cat = item.category?.lowercased() ?? ""
            let categoryPenalty: Double
            switch cat {
            case "marketing":      categoryPenalty = -15
            case "notification":   categoryPenalty = -10
            case "transactional":  categoryPenalty = -5
            default:               categoryPenalty = 0
            }

            let total = replyScore + recencyBonus + unreadBonus + sourceBonus + categoryPenalty
            return (item, max(0, total))
        }

        // Sort by priority tier first (must > should > low), then by score within each tier
        return scored
            .filter { $0.1 > 0 }
            .sorted { a, b in
                let tierA = a.0.priority
                let tierB = b.0.priority
                if tierA != tierB { return tierA < tierB }  // .must < .should < .low (Comparable)
                return a.1 > b.1  // Within same tier, higher score first
            }
            .map { $0.0 }
    }
}

