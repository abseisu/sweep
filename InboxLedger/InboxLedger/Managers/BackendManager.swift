// Managers/BackendManager.swift
// API client for the Ledger backend. All backend calls go through here.
// JWT stored in Keychain, auto-refreshes when near expiry.

import Foundation

final class BackendManager {
    static let shared = BackendManager()

    private let baseURL = "https://ledger-api-adnanbseisu.fly.dev"

    /// Guards against re-entrant refresh loops
    private var isRefreshing = false

    private var jwt: String? {
        get { KeychainHelper.get("ledger_jwt") }
        set {
            if let v = newValue { KeychainHelper.set(v, forKey: "ledger_jwt") }
            else { KeychainHelper.delete("ledger_jwt") }
        }
    }

    private var jwtExpiry: Date? {
        get { UserDefaults.standard.object(forKey: "ledger_jwt_expiry") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "ledger_jwt_expiry") }
    }

    var isAuthenticated: Bool { jwt != nil && (jwtExpiry ?? .distantPast) > Date() }

    /// True if the user has ever registered with the backend (has a JWT, even if expired — can refresh)
    var isRegistered: Bool { jwt != nil }

    /// Ensure the device is registered with the backend (creates a user if needed).
    /// Always verifies the JWT is actually valid — handles DB wipes, expired tokens, etc.
    func ensureRegistered() async throws {
        // If we have a JWT, test it with a lightweight call
        if jwt != nil {
            // Quick local check: expired?
            if let expiry = jwtExpiry, expiry < Date() {
                print("🔑 JWT expired locally, clearing")
                jwt = nil
                // Fall through to re-register
            } else {
                // Verify it actually works against the backend
                var testReq = URLRequest(url: URL(string: "\(baseURL)/auth/refresh")!)
                testReq.httpMethod = "POST"
                testReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                testReq.setValue("Bearer \(jwt!)", forHTTPHeaderField: "Authorization")
                testReq.httpBody = "{}".data(using: .utf8)
                testReq.timeoutInterval = 10

                struct RefreshCheck: Decodable { let jwt: String; let expiresAt: String }

                if let (data, response) = try? await URLSession.shared.data(for: testReq),
                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let resp = try? JSONDecoder().decode(RefreshCheck.self, from: data) {
                    // JWT is valid — update it with the fresh one
                    print("🔑 Existing JWT verified OK")
                    jwt = resp.jwt
                    jwtExpiry = ISO8601DateFormatter().date(from: resp.expiresAt)
                    return
                }
                // JWT is stale/invalid — clear and re-register
                print("🔑 JWT verification failed, re-registering")
                jwt = nil
                jwtExpiry = nil
            }
        }

        // Register (or re-register) the device
        print("🔑 Calling /auth/register-device...")
        var urlRequest = URLRequest(url: URL(string: "\(baseURL)/auth/register-device")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 15

        // Detect fresh install: check for a Keychain sentinel that survives UserDefaults wipes
        // but IS deleted when the app is deleted (Keychain items with kSecAttrAccessible
        // are removed on app deletion on real devices).
        let isFreshInstall = KeychainHelper.get("sweep_installed_sentinel") == nil
        if isFreshInstall {
            // Set the sentinel so next time we know it's not a fresh install
            KeychainHelper.set("1", forKey: "sweep_installed_sentinel")
            print("🔑 Fresh install detected — will request ledger reset")
        }

        struct DeviceRegister: Encodable { let deviceId: String; let previousUserId: String?; let freshInstall: Bool }
        let deviceId = getOrCreateDeviceId()
        let previousUserId = UserDefaults.standard.string(forKey: "ledger_user_id")
        print("🔑 Device ID: \(deviceId), previous user: \(previousUserId?.prefix(8) ?? "none"), freshInstall: \(isFreshInstall)")
        urlRequest.httpBody = try JSONEncoder().encode(DeviceRegister(deviceId: deviceId, previousUserId: previousUserId, freshInstall: isFreshInstall))

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            print("🔑 ❌ No HTTP response")
            throw BackendError.invalidResponse
        }
        print("🔑 register-device status: \(http.statusCode)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("🔑 ❌ register-device failed: \(body)")
            throw BackendError.httpError(http.statusCode, body)
        }

        let resp = try JSONDecoder().decode(AuthResponse.self, from: data)
        jwt = resp.jwt
        jwtExpiry = ISO8601DateFormatter().date(from: resp.expiresAt)
        UserDefaults.standard.set(resp.userId, forKey: "ledger_user_id")
        print("🔑 ✅ Registered as user \(resp.userId.prefix(8))...")
    }

    // MARK: - Generic Request (with auto-recovery on 401)

    func request<T: Decodable>(
        _ method: String, path: String, body: Encodable? = nil, isRetry: Bool = false
    ) async throws -> T {
        // Auto-refresh JWT if expiring within 1 hour (but not if already refreshing)
        if !isRefreshing, let expiry = jwtExpiry, expiry.timeIntervalSinceNow < 3600, jwt != nil {
            try? await refreshJWT()
        }

        var urlRequest = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 30
        if let jwt = jwt {
            urlRequest.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        // If 401 and this is NOT already a retry, try re-registering from scratch
        if http.statusCode == 401 && !isRetry {
            do {
                // Clear stale JWT and re-register
                jwt = nil
                jwtExpiry = nil
                try await ensureRegistered()
                return try await request(method, path: path, body: body, isRetry: true)
            } catch {
                throw BackendError.httpError(401, "Authentication failed after re-registration")
            }
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.httpError(http.statusCode, body)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Auth

    struct RegisterRequest: Encodable {
        let provider: String
        let accessToken: String
        let refreshToken: String
        let email: String
        let displayName: String?
        let deviceToken: String?
        let deviceId: String
    }

    struct AuthResponse: Decodable {
        let jwt: String
        let userId: String
        let expiresAt: String
    }

    func register(
        provider: String,
        accessToken: String,
        refreshToken: String,
        email: String,
        displayName: String?,
        deviceToken: String?
    ) async throws {
        // Registration uses a direct URL request (not the generic request method)
        // because we don't have a JWT yet
        var urlRequest = URLRequest(url: URL(string: "\(baseURL)/auth/register")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = try JSONEncoder().encode(RegisterRequest(
            provider: provider,
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            displayName: displayName,
            deviceToken: deviceToken,
            deviceId: getOrCreateDeviceId()
        ))

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackendError.httpError(http.statusCode, body)
        }

        let resp = try JSONDecoder().decode(AuthResponse.self, from: data)
        jwt = resp.jwt
        jwtExpiry = ISO8601DateFormatter().date(from: resp.expiresAt)
        UserDefaults.standard.set(resp.userId, forKey: "ledger_user_id")
    }

    func logout() {
        jwt = nil
        jwtExpiry = nil
        UserDefaults.standard.removeObject(forKey: "ledger_user_id")
        UserDefaults.standard.removeObject(forKey: "ledger_jwt_expiry")
    }

    private func refreshJWT() async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard jwt != nil else {
            throw BackendError.httpError(401, "No JWT to refresh")
        }

        var urlRequest = URLRequest(url: URL(string: "\(baseURL)/auth/refresh")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 15
        if let jwt = jwt {
            urlRequest.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        // Send empty JSON body to avoid Fastify empty-body error
        urlRequest.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BackendError.httpError(code, "JWT refresh failed")
        }

        struct RefreshResponse: Decodable {
            let jwt: String
            let expiresAt: String
        }
        let r = try JSONDecoder().decode(RefreshResponse.self, from: data)
        jwt = r.jwt
        jwtExpiry = ISO8601DateFormatter().date(from: r.expiresAt)
    }

    // MARK: - Score (Unlimited)

    struct ScoreRequest: Encodable {
        let emails: [EmailForScoring]
        let styleContext: String?
    }

    struct EmailForScoring: Encodable {
        let id: String
        let from: String
        let fromEmail: String
        let subject: String
        let body: String
        let source: String
        let isUnread: Bool
        let hasReplied: Bool
        let attachmentSummary: String?
        let linkSummary: String?
        let recipients: String?
        let date: String?
    }

    struct ScoreResponse: Decodable {
        let scores: [EmailScore]
    }

    struct EmailScore: Decodable {
        let id: String
        let replyability: Int
        let summary: String?
        let draft: String?
        let tone: String?
        let category: String?
        let suggestReplyAll: Bool?
    }

    func scoreEmails(_ emails: [EmailForScoring], styleContext: String? = nil) async throws -> [EmailScore] {
        let r: ScoreResponse = try await request("POST", path: "/score",
            body: ScoreRequest(emails: emails, styleContext: styleContext))
        return r.scores
    }

    // MARK: - Redraft (Unlimited)

    struct RedraftRequest: Encodable {
        let email: EmailForScoring
        let currentDraft: String
        let instruction: String
        let redraftCount: Int
        let styleContext: String?
    }

    struct RedraftResponse: Decodable {
        let draft: String
    }

    func redraft(
        email: EmailForScoring,
        currentDraft: String,
        instruction: String,
        redraftCount: Int,
        styleContext: String? = nil
    ) async throws -> String {
        let r: RedraftResponse = try await request("POST", path: "/redraft",
            body: RedraftRequest(
                email: email,
                currentDraft: currentDraft,
                instruction: instruction,
                redraftCount: redraftCount,
                styleContext: styleContext
            ))
        return r.draft
    }

    // MARK: - Send Email

    struct SendRequest: Encodable {
        let accountId: String
        let to: String
        let subject: String
        let body: String
        let threadId: String
        let messageId: String
        let replyAll: Bool
        let fromName: String?
        let fromEmail: String?
    }

    func sendReply(_ req: SendRequest) async throws {
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await request("POST", path: "/send", body: req)
    }

    // MARK: - Device Token (APNs)

    func updateDeviceToken(_ token: String) async {
        struct DeviceTokenRequest: Encodable {
            let deviceToken: String
            let deviceId: String
        }
        struct OK: Decodable { let ok: Bool }
        try? await (request("POST", path: "/auth/device",
            body: DeviceTokenRequest(deviceToken: token, deviceId: getOrCreateDeviceId())) as OK)
    }

    // MARK: - Settings Sync

    struct SettingsUpdate: Encodable {
        let mode: String?
        let windowHour: Int?
        let windowMinute: Int?
        let sensitivity: Int?
        let snoozeHours: Int?
        let scoreThreshold: Int?
        let scanIntervalMinutes: Int?
    }

    func syncSettings(_ update: SettingsUpdate) async {
        struct OK: Decodable { let ok: Bool }
        try? await (request("PUT", path: "/user/settings", body: update) as OK)
    }

    // MARK: - Subscription

    struct SubscriptionInfo: Decodable {
        let tier: String
        let trialActive: Bool?
        let expiresAt: String?
    }

    func getSubscription() async throws -> SubscriptionInfo {
        return try await request("GET", path: "/user/subscription")
    }

    struct VerifyReceiptRequest: Encodable {
        let receiptData: String
    }

    func verifyReceipt(_ receiptData: String) async throws {
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await request("POST", path: "/subscription/verify",
            body: VerifyReceiptRequest(receiptData: receiptData))
    }

    // MARK: - Delete Account

    func deleteAccount() async throws {
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await request("DELETE", path: "/auth/account")
        logout()
    }

    // MARK: - Ledger (Pre-scored Items from Background Scans)

    struct LedgerResponse: Decodable {
        let items: [LedgerItem]
        let count: Int
        let lastScanAt: String?
    }

    struct LedgerItem: Decodable {
        let id: String
        let source: String
        let threadId: String?
        let messageId: String?
        let senderName: String?
        let senderEmail: String?
        let subject: String?
        let snippet: String?
        let body: String?
        let date: String
        let isUnread: Bool?
        let accountId: String?
        let toRecipients: [String]?
        let ccRecipients: [String]?
        let conversationContext: String?  // JSON string for iMessage conversation history
        let replyability: Int
        let aiSummary: String?
        let suggestedDraft: String?
        let detectedTone: String?
        let category: String?
        let suggestReplyAll: Bool?
    }

    /// Fetch pre-scored ledger items from the backend (background-scanned & AI-scored).
    func fetchLedger() async throws -> LedgerResponse {
        return try await request("GET", path: "/ledger")
    }

    /// Mark items as dismissed on the backend.
    func dismissItems(_ ids: [String]) async {
        struct DismissRequest: Encodable { let ids: [String] }
        struct OK: Decodable { let ok: Bool }
        try? await (request("POST", path: "/ledger/dismiss", body: DismissRequest(ids: ids)) as OK)
    }

    /// Reset all dismissed items back to active (fresh install).
    func resetLedger() async {
        struct OK: Decodable { let ok: Bool }
        try? await (request("POST", path: "/ledger/reset") as OK)
    }

    /// Snooze items until a given time on the backend.
    func snoozeItems(_ ids: [String], until: Date) async {
        struct SnoozeRequest: Encodable { let ids: [String]; let until: String }
        struct OK: Decodable { let ok: Bool }
        let formatter = ISO8601DateFormatter()
        let untilStr = formatter.string(from: until)
        try? await (request("POST", path: "/ledger/snooze", body: SnoozeRequest(ids: ids, until: untilStr)) as OK)
    }

    /// Mark an item as sent on the backend.
    func markSent(_ id: String) async {
        struct SentRequest: Encodable { let id: String }
        struct OK: Decodable { let ok: Bool }
        try? await (request("POST", path: "/ledger/sent", body: SentRequest(id: id)) as OK)
    }

    /// Update draft text for an item on the backend.
    func updateDraft(id: String, draft: String) async {
        struct DraftRequest: Encodable { let id: String; let draft: String }
        struct OK: Decodable { let ok: Bool }
        try? await (request("PUT", path: "/ledger/draft", body: DraftRequest(id: id, draft: draft)) as OK)
    }

    // MARK: - iMessage Relay

    /// Queue an iMessage reply to be sent by the Mac companion app.
    func sendIMessageReply(recipient: String, text: String, itemId: String?) async {
        struct ReplyRequest: Encodable { let recipient: String; let text: String; let itemId: String? }
        struct ReplyResponse: Decodable { let ok: Bool; let replyId: String? }
        do {
            let response: ReplyResponse = try await request("POST", path: "/imessage/reply", body: ReplyRequest(recipient: recipient, text: text, itemId: itemId))
            print("📨 iMessage reply queued: ok=\(response.ok), replyId=\(response.replyId ?? "nil"), recipient=\(recipient)")
        } catch {
            print("❌ iMessage reply failed: \(error.localizedDescription) — recipient=\(recipient)")
        }
    }

    /// Disconnect the iMessage relay.
    func disconnectIMessage() async {
        struct OK: Decodable { let ok: Bool }
        try? await (request("POST", path: "/imessage/disconnect") as OK)
    }

    // MARK: - Helpers

    private func getOrCreateDeviceId() -> String {
        if let id = UserDefaults.standard.string(forKey: "ledger_device_id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "ledger_device_id")
        return id
    }
}

// MARK: - LedgerItem → LedgerEmail Conversion

extension BackendManager.LedgerItem {
    func toLedgerEmail() -> LedgerEmail {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsedDate = dateFormatter.date(from: date)
            ?? ISO8601DateFormatter().date(from: date)
            ?? Date()

        let parsedSource = LedgerSource(rawValue: source) ?? .imessage

        var email = LedgerEmail(
            id: id,
            source: parsedSource,
            threadId: threadId ?? "",
            messageId: messageId ?? "",
            senderName: senderName ?? "Unknown",
            senderEmail: senderEmail ?? "",
            subject: subject ?? "",
            snippet: snippet ?? "",
            body: body ?? "",
            date: parsedDate,
            isUnread: isUnread ?? true,
            accountId: accountId ?? "",
            toRecipients: toRecipients ?? [],
            ccRecipients: ccRecipients ?? [],
            aiSummary: aiSummary,
            suggestedDraft: suggestedDraft,
            detectedTone: detectedTone,
            replyability: replyability,
            category: category,
            suggestReplyAll: suggestReplyAll ?? false
        )

        // For iMessage items, pass conversation context through
        if let ctx = conversationContext, !ctx.isEmpty {
            email.conversationContext = ctx
        }

        return email
    }
}

// MARK: - Error Type

enum BackendError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .httpError(let code, let body): return "Server error (\(code)): \(body)"
        }
    }
}

