// RelayState.swift
// Central state for the Sweep Relay Mac app.

import SwiftUI
import Combine
import ServiceManagement
import SQLite3
import Security

@MainActor
final class RelayState: ObservableObject {
    // MARK: - Pairing
    @Published var isPaired: Bool = false
    @Published var pairingCode: String = ""
    @Published var pairingError: String?
    @Published var isPairing: Bool = false

    // MARK: - Status
    @Published var isRunning: Bool = false
    @Published var lastSyncTime: Date?
    @Published var messagesSynced: Int = 0
    @Published var repliesSent: Int = 0
    @Published var hasFullDiskAccess: Bool = false
    @Published var hasAutomationAccess: Bool = false
    @Published var connectionStatus: ConnectionStatus = .disconnected

    enum ConnectionStatus: String {
        case connected = "Connected"
        case disconnected = "Disconnected"
        case syncing = "Syncing..."
        case error = "Error"
    }

    // MARK: - Services
    private var chatReader: ChatDBReader?
    private var syncTimer: Timer?
    private var replyTimer: Timer?
    private var healthTimer: Timer?
    private let api = RelayAPI()

    // MARK: - Persistence Keys
    private let jwtKey = "relay_jwt"
    private let userIdKey = "relay_user_id"
    private let lastMessageDateKey = "relay_last_message_date"

    var jwt: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: jwtKey,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            // Delete existing
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: jwtKey
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            // Add new value if non-nil
            if let value = newValue, let data = value.data(using: .utf8) {
                let addQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: jwtKey,
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                ]
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
    }

    var userId: String? {
        get { UserDefaults.standard.string(forKey: userIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: userIdKey) }
    }

    var lastMessageDate: Date? {
        get { UserDefaults.standard.object(forKey: lastMessageDateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastMessageDateKey) }
    }

    // MARK: - Init

    init() {
        // Detect fresh install: macOS preserves UserDefaults even after deleting an app.
        // Use a sentinel key to detect if this is a genuinely configured instance.
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "relay_setup_completed")
        
        if !hasCompletedSetup {
            // Fresh install or re-install — clear any stale credentials from previous install
            UserDefaults.standard.removeObject(forKey: jwtKey)
            UserDefaults.standard.removeObject(forKey: userIdKey)
            UserDefaults.standard.removeObject(forKey: lastMessageDateKey)
        }

        hasFullDiskAccess = checkFullDiskAccess()

        // Don't trust local JWT alone — verify with backend on every launch
        if jwt != nil && userId != nil && hasCompletedSetup {
            Task { await verifyPairingWithBackend() }
        } else {
            isPaired = false
        }
    }

    // MARK: - Backend Verification

    /// Verify that our JWT is actually valid and the pairing exists on the backend.
    /// This prevents the ghost "connected" state when iOS has disconnected or re-registered.
    private func verifyPairingWithBackend() async {
        guard let token = jwt else {
            markDisconnected()
            return
        }

        do {
            // Hit an authenticated endpoint to verify our JWT is still valid
            struct RepliesResponse: Decodable { let replies: [PendingReply] }
            let _: RepliesResponse = try await authenticatedGet("/imessage/replies", jwt: token)

            // JWT is valid — we're actually paired
            isPaired = true
            connectionStatus = .connected
            if hasFullDiskAccess && !isRunning {
                startSyncing()
            }
            startHealthChecks()
            print("✅ Backend verified — pairing is live")
        } catch RelayAPIError.httpError(401) {
            // JWT rejected — try re-auth
            print("⚠️ JWT rejected on startup — attempting re-auth...")
            await attemptReauth()
            if connectionStatus != .error {
                isPaired = true
                if hasFullDiskAccess && !isRunning {
                    startSyncing()
                }
                startHealthChecks()
            } else {
                // Re-auth also failed — this pairing is dead
                markDisconnected()
            }
        } catch {
            // Network error — give benefit of the doubt temporarily
            // Will re-verify on next health check
            print("⚠️ Could not verify pairing (network): \(error.localizedDescription)")
            isPaired = true
            connectionStatus = .connected
            if hasFullDiskAccess && !isRunning {
                startSyncing()
            }
            startHealthChecks()
        }
    }

    /// Simple authenticated GET that throws RelayAPIError on non-2xx
    private func authenticatedGet<T: Decodable>(_ path: String, jwt: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://ledger-api-adnanbseisu.fly.dev\(path)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RelayAPIError.httpError(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw RelayAPIError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Periodic health check — verifies backend pairing is still alive every 60s
    private func startHealthChecks() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.healthCheck()
            }
        }
    }

    private var replyRetryCount: [String: Int] = [:]
    private var replyRetryCount: [String: Int] = [:]
    private var consecutiveUnpairedChecks = 0

    private func healthCheck() async {
        guard let token = jwt else {
            markDisconnected()
            return
        }

        do {
            // Check if we're still paired (iOS may have disconnected us)
            struct RelayStatus: Decodable { let paired: Bool; let reason: String? }
            let status: RelayStatus = try await authenticatedGet("/imessage/relay-status", jwt: token)
            if !status.paired {
                consecutiveUnpairedChecks += 1
                print("⚠️ relay-status: paired=false (attempt \(consecutiveUnpairedChecks)/3, reason: \(status.reason ?? "none"))")
                if consecutiveUnpairedChecks >= 3 {
                    print("🔌 iOS confirmed disconnect after 3 checks — reverting to setup")
                    markDisconnected()
                }
            } else {
                consecutiveUnpairedChecks = 0
            }
        } catch RelayAPIError.httpError(401) {
            consecutiveUnpairedChecks += 1
            print("⚠️ Health check 401 (attempt \(consecutiveUnpairedChecks)/3)")
            if consecutiveUnpairedChecks >= 3 {
                await attemptReauth()
                if connectionStatus == .error {
                    markDisconnected()
                }
            }
        } catch {
            // Network blip — don't disconnect yet
            print("⚠️ Health check failed (network): \(error.localizedDescription)")
        }
    }

    /// Clear all local state and show setup screen
    private func markDisconnected() {
        stopSyncing()
        healthTimer?.invalidate()
        healthTimer = nil
        jwt = nil
        userId = nil
        isPaired = false
        lastMessageDate = nil
        messagesSynced = 0
        repliesSent = 0
        connectionStatus = .disconnected
        UserDefaults.standard.set(false, forKey: "relay_setup_completed")
        print("🔌 Marked as disconnected — showing setup")
    }

    // MARK: - Pairing

    func pair(code: String) async {
        isPairing = true
        pairingError = nil

        do {
            let result = try await api.confirmPairing(code: code.uppercased().trimmingCharacters(in: .whitespaces))
            jwt = result.jwt
            userId = result.userId
            isPaired = true
            isPairing = false
            connectionStatus = .connected

            // Mark that setup has been completed on THIS install
            UserDefaults.standard.set(true, forKey: "relay_setup_completed")

            if hasFullDiskAccess {
                startSyncing()
            }
            startHealthChecks()
        } catch {
            pairingError = "Pairing failed. Check your code and try again."
            isPairing = false
        }
    }

    func unpair() {
        if let token = jwt {
            Task {
                try? await api.disconnect(jwt: token)
            }
        }
        markDisconnected()
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccess() -> Bool {
        // IMPORTANT: FileManager.isReadableFile checks POSIX permissions, NOT macOS TCC.
        // The ONLY reliable way to check FDA is to actually open the protected file.
        // This triggers the real TCC check that macOS enforces.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let chatDBPath = "\(home)/Library/Messages/chat.db"

        // Method 1: Try to open chat.db with SQLite — this is exactly what ChatDBReader does,
        // so if this works, syncing will work too.
        var db: OpaquePointer?
        let result = sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil)
        if result == SQLITE_OK {
            // Actually try a query to be sure
            var stmt: OpaquePointer?
            let queryResult = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message LIMIT 1", -1, &stmt, nil)
            sqlite3_finalize(stmt)
            sqlite3_close(db)
            if queryResult == SQLITE_OK {
                print("✅ FDA check: SQLite query succeeded")
            }
            return queryResult == SQLITE_OK
        }
        sqlite3_close(db)

        // Method 2: Try raw file read as fallback
        do {
            let _ = try Data(contentsOf: URL(fileURLWithPath: chatDBPath), options: .mappedIfSafe)
            print("✅ FDA check: raw file read succeeded")
            return true
        } catch {
            print("❌ FDA check failed: \(error.localizedDescription)")
        }

        return false
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = checkFullDiskAccess()
        if isPaired && hasFullDiskAccess && !isRunning {
            startSyncing()
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Syncing

    func startSyncing() {
        guard isPaired, hasFullDiskAccess, !isRunning else { return }

        chatReader = ChatDBReader()
        isRunning = true
        connectionStatus = .connected

        // Sync every 30 seconds
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncMessages()
            }
        }

        // Initial sync immediately
        Task { await syncMessages() }

        // Check for pending replies every 15 seconds
        replyTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkPendingReplies()
            }
        }

        // Enable launch at login
        enableLaunchAtLogin()

        print("✅ Syncing started")
    }

    func stopSyncing() {
        syncTimer?.invalidate()
        syncTimer = nil
        replyTimer?.invalidate()
        replyTimer = nil
        isRunning = false
        connectionStatus = .disconnected
        chatReader = nil
    }

    private func syncMessages() async {
        guard let reader = chatReader, let token = jwt else { return }
        connectionStatus = .syncing

        do {
            // Step 1: Re-verify all active items — dismiss any the user already replied to.
            // This catches replies sent from iPhone while the Mac was off.
            do {
                let allChats = try reader.allRecentChatIds(limit: 50)
                if !allChats.isEmpty {
                    let replyDates = (try? reader.lastReplyDates(for: allChats)) ?? [:]
                    if !replyDates.isEmpty {
                        let dismissed = try await api.verifyActive(lastReplyDates: replyDates, jwt: token)
                        if dismissed > 0 {
                            print("🧹 Verified active items: dismissed \(dismissed) already-replied cards")
                        }
                    }
                }
            } catch {
                print("⚠️ Verify-active failed (non-fatal): \(error.localizedDescription)")
            }

            // Step 2: Fetch and push new messages as usual
            let since: Date
            if let last = lastMessageDate {
                since = last
            } else {
                // First sync after pairing — look back 24 hours to match iOS email fetch window
                since = Date().addingTimeInterval(-24 * 60 * 60)
                print("📬 First sync — looking back 24 hours")
            }

            print("📬 Fetching messages since \(since) (\(Int(-since.timeIntervalSinceNow / 60)) min ago)")
            let messages = try reader.fetchNewMessages(since: since, limit: 50)
            print("📬 ChatDBReader returned \(messages.count) messages")

            if !messages.isEmpty {
                // Log what we found
                for msg in messages.prefix(5) {
                    print("   📨 \(msg.isFromMe ? "→" : "←") \(msg.senderName): [message]")
                }
                if messages.count > 5 {
                    print("   ... and \(messages.count - 5) more")
                }

                let chatIds = Set(messages.map { $0.chatId })
                let replyDates = (try? reader.lastReplyDates(for: chatIds)) ?? [:]

                let batchSize = 10
                for start in stride(from: 0, to: messages.count, by: batchSize) {
                    let end = min(start + batchSize, messages.count)
                    let batch = Array(messages[start..<end])
                    try await api.pushMessages(batch, lastReplyDates: replyDates, jwt: token)
                    print("📬 Pushed batch of \(batch.count) messages")
                }
                messagesSynced += messages.count
                lastMessageDate = messages.map { $0.date }.max() ?? Date()
                print("📬 Synced \(messages.count) new iMessages total")
            } else {
                print("📬 No new messages found since \(since)")
            }

            lastSyncTime = Date()
            connectionStatus = .connected
            consecutiveUnpairedChecks = 0  // Reset on successful sync
        } catch RelayAPIError.httpError(401) {
            consecutiveUnpairedChecks += 1
            print("⚠️ Sync got 401 (attempt \(consecutiveUnpairedChecks)/3)")
            if consecutiveUnpairedChecks >= 3 {
                print("⚠️ Sync 401 persistent — attempting re-auth...")
                await attemptReauth()
                if connectionStatus == .error {
                    markDisconnected()
                }
            }
        } catch {
            print("❌ Sync failed: \(error.localizedDescription)")
            connectionStatus = .error
        }
    }

    private func checkPendingReplies() async {
        guard let token = jwt else { return }

        do {
            let replies = try await api.getPendingReplies(jwt: token)
            if !replies.isEmpty {
                print("📬 Found \(replies.count) pending replies to send")
            }
            for reply in replies {
                print("📨 Sending reply to [recipient]: [message]")
                let sent = await AppleScriptSender.sendMessage(to: reply.recipient, text: reply.text)
                if sent {
                    try? await api.ackReply(id: reply.id, jwt: token)
                    repliesSent += 1
                    hasAutomationAccess = true
                    print("✅ Sent reply to \(reply.recipient)")
                } else {
                    print("❌ Failed to send reply to \(reply.recipient)")
                    let count = (replyRetryCount[reply.id] ?? 0) + 1
                    replyRetryCount[reply.id] = count
                    if count >= 3 {
                        // Give up after 3 attempts — ack to remove from queue
                        try? await api.ackReply(id: reply.id, jwt: token)
                        replyRetryCount.removeValue(forKey: reply.id)
                        print("⚠️ Gave up on reply \(reply.id) after 3 attempts")
                    }
                    // Check if it's an automation permission issue
                    if !AppleScriptSender.checkAutomationPermission() {
                        hasAutomationAccess = false
                        print("🔒 Automation permission not granted for Messages — replies will fail until fixed")
                        print("🔒 User needs: System Settings → Privacy & Security → Automation → Sweep Relay → Messages ON")
                    }
                }
            }
        } catch RelayAPIError.httpError(401) {
            print("⚠️ Reply poll got 401 — attempting re-auth...")
            await attemptReauth()
            if connectionStatus == .error {
                markDisconnected()
            }
        } catch {
            print("⚠️ Reply poll error: \(error.localizedDescription)")
        }
    }

    /// Attempts to re-authenticate with the backend when the JWT is rejected.
    private func attemptReauth() async {
        guard let oldUserId = userId else {
            connectionStatus = .error
            return
        }

        do {
            let result = try await api.reauth(oldUserId: oldUserId, macDeviceId: "mac_relay_\(oldUserId)")
            jwt = result.jwt
            userId = result.userId
            connectionStatus = .connected
            print("🔄 Re-auth succeeded — new JWT for user \(result.userId.prefix(8))...")
        } catch {
            print("❌ Re-auth failed: \(error.localizedDescription) — need to re-pair")
            connectionStatus = .error
        }
    }

    // MARK: - Launch at Login

    private func enableLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }

    func disableLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        }
    }
}
