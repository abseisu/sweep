# iOS App Changes for Backend Integration

Every change needed in the iOS app to connect to the backend.
Do them in this order.

---

## 1. Add BackendManager.swift (New File)

This is the API client. Every call to the backend goes through here.

```swift
// Managers/BackendManager.swift

import Foundation

final class BackendManager {
    static let shared = BackendManager()

    // CHANGE THIS to your Fly.io URL after deployment
    private let baseURL = "https://ledger-api.fly.dev"

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

    // ── Generic Request ──

    private func request<T: Decodable>(
        _ method: String, path: String, body: Encodable? = nil
    ) async throws -> T {
        if let expiry = jwtExpiry, expiry.timeIntervalSinceNow < 3600, jwt != nil {
            try? await refreshJWT()
        }

        var urlRequest = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt = jwt { urlRequest.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        if let body = body { urlRequest.httpBody = try JSONEncoder().encode(body) }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }

        if http.statusCode == 401 {
            try await refreshJWT()
            return try await request(method, path: path, body: body)
        }

        guard (200...299).contains(http.statusCode) else {
            throw BackendError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // ── Auth ──

    struct RegisterRequest: Encodable {
        let provider: String; let accessToken: String; let refreshToken: String
        let email: String; let displayName: String?
        let deviceToken: String?; let deviceId: String
    }
    struct AuthResponse: Decodable { let jwt: String; let userId: String; let expiresAt: String }

    func register(provider: String, accessToken: String, refreshToken: String,
                  email: String, displayName: String?, deviceToken: String?) async throws {
        let resp: AuthResponse = try await request("POST", path: "/auth/register", body: RegisterRequest(
            provider: provider, accessToken: accessToken, refreshToken: refreshToken,
            email: email, displayName: displayName, deviceToken: deviceToken,
            deviceId: getOrCreateDeviceId()
        ))
        jwt = resp.jwt
        jwtExpiry = ISO8601DateFormatter().date(from: resp.expiresAt)
        UserDefaults.standard.set(resp.userId, forKey: "ledger_user_id")
    }

    private func refreshJWT() async throws {
        struct R: Decodable { let jwt: String; let expiresAt: String }
        let r: R = try await request("POST", path: "/auth/refresh")
        jwt = r.jwt; jwtExpiry = ISO8601DateFormatter().date(from: r.expiresAt)
    }

    // ── Score (Unlimited) ──

    struct ScoreRequest: Encodable { let emails: [EmailForScoring]; let styleContext: String? }
    struct EmailForScoring: Encodable {
        let id, from, fromEmail, subject, body, source: String
        let isUnread: Bool; let hasReplied: Bool
        let attachmentSummary, linkSummary, recipients: String?
    }
    struct ScoreResponse: Decodable { let scores: [EmailScore] }
    struct EmailScore: Decodable {
        let id: String; let replyability: Int
        let summary, draft, tone, category: String?; let suggestReplyAll: Bool?
    }

    func scoreEmails(_ emails: [EmailForScoring], styleContext: String? = nil) async throws -> [EmailScore] {
        let r: ScoreResponse = try await request("POST", path: "/score",
            body: ScoreRequest(emails: emails, styleContext: styleContext))
        return r.scores
    }

    // ── Redraft (Unlimited) ──

    struct RedraftRequest: Encodable {
        let email: EmailForScoring; let currentDraft, instruction: String
        let redraftCount: Int; let styleContext: String?
    }
    struct RedraftResponse: Decodable { let draft: String }

    func redraft(email: EmailForScoring, currentDraft: String, instruction: String,
                 redraftCount: Int, styleContext: String? = nil) async throws -> String {
        let r: RedraftResponse = try await request("POST", path: "/redraft",
            body: RedraftRequest(email: email, currentDraft: currentDraft,
                instruction: instruction, redraftCount: redraftCount, styleContext: styleContext))
        return r.draft
    }

    // ── Send ──

    struct SendRequest: Encodable {
        let accountId, to, subject, body, threadId, messageId: String
        let replyAll: Bool; let fromName, fromEmail: String?
    }

    func sendReply(_ req: SendRequest) async throws {
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await request("POST", path: "/send", body: req)
    }

    // ── Device Token ──

    func updateDeviceToken(_ token: String) async {
        struct R: Encodable { let deviceToken, deviceId: String }
        struct OK: Decodable { let ok: Bool }
        try? await (request("POST", path: "/auth/device",
            body: R(deviceToken: token, deviceId: getOrCreateDeviceId())) as OK)
    }

    // ── Settings Sync ──

    struct SettingsUpdate: Encodable {
        let mode: String?; let windowHour, windowMinute, sensitivity: Int?
        let snoozeHours, scoreThreshold, scanIntervalMinutes: Int?
    }

    func syncSettings(_ update: SettingsUpdate) async {
        struct OK: Decodable { let ok: Bool }
        try? await (request("PUT", path: "/user/settings", body: update) as OK)
    }

    // ── Helpers ──

    private func getOrCreateDeviceId() -> String {
        if let id = UserDefaults.standard.string(forKey: "ledger_device_id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "ledger_device_id")
        return id
    }
}

enum BackendError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .httpError(let c, let b): return "HTTP \(c): \(b)"
        }
    }
}
```

---

## 2. Add KeychainHelper.swift (New File)

```swift
// Managers/KeychainHelper.swift

import Security
import Foundation

enum KeychainHelper {
    static func set(_ value: String, forKey key: String) {
        let data = value.data(using: .utf8)!
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrAccount as String: key, kSecValueData as String: data]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrAccount as String: key,
                                 kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
              let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: key] as CFDictionary)
    }
}
```

---

## 3. Modify GmailManager — Get Refresh Token

Add `serverClientID` so Google provides a refresh token:

```swift
// In GmailManager.signIn() — add serverClientID
let config = GIDConfiguration(
    clientID: clientID,
    serverClientID: "YOUR_WEB_CLIENT_ID.apps.googleusercontent.com"  // From Step 3
)

// After sign-in, get the server auth code:
guard let serverAuthCode = user.serverAuthCode else {
    throw GmailError.noAuthCode
}

// Register with backend:
try await BackendManager.shared.register(
    provider: "gmail",
    accessToken: result.accessToken,
    refreshToken: serverAuthCode,  // Backend exchanges this for refresh token
    email: result.email,
    displayName: result.displayName,
    deviceToken: currentAPNsToken
)
```

---

## 4. Modify AIManager — Route Through Backend

Replace direct API calls with backend proxy:

```swift
// In AIManager — replace analyzeWith()

private func analyzeWith(email: LedgerEmail, provider: AIProvider) async throws -> AIResponse {
    let e = BackendManager.EmailForScoring(
        id: email.id, from: email.senderName, fromEmail: email.senderEmail,
        subject: email.subject, body: String(email.body.prefix(10000)),
        source: email.source.rawValue, isUnread: email.isUnread,
        hasReplied: email.userHasReplied,
        attachmentSummary: email.attachmentSummary, linkSummary: nil,
        recipients: email.toRecipients.joined(separator: ", ")
    )

    let scores = try await BackendManager.shared.scoreEmails([e])
    guard let s = scores.first else { throw AIError.noResponse }

    return AIResponse(
        summary: s.summary ?? "", draft: s.draft,
        replyability: s.replyability, tone: s.tone ?? "neutral",
        category: s.category ?? "personal",
        suggestReplyAll: s.suggestReplyAll ?? false
    )
}
```

---

## 5. Register for APNs + Forward Device Token

In `AppDelegate.swift`:

```swift
func application(_ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    Task { await BackendManager.shared.updateDeviceToken(token) }
}

func application(_ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error) {
    print("⚠️ APNs registration failed: \(error)")
}
```

In `InboxLedgerApp.swift` or `AppState.init()`:
```swift
UIApplication.shared.registerForRemoteNotifications()
```

---

## 6. Sync Settings to Backend

Whenever mode, sensitivity, snooze, or window time changes:

```swift
Task {
    await BackendManager.shared.syncSettings(.init(
        mode: ledgerMode.rawValue,
        sensitivity: batchSensitivity,
        snoozeHours: snoozeHours,
        windowHour: windowHour, windowMinute: windowMinute,
        scoreThreshold: scoreThreshold,
        scanIntervalMinutes: nil  // Determined by tier, set server-side
    ))
}
```

---

## 7. Handle Push Notification Deep Links

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {

    if let type = response.notification.request.content.userInfo["type"] as? String {
        switch type {
        case "batch", "window", "urgent":
            NotificationCenter.default.post(name: .ledgerOpenDashboard, object: nil)
        default: break
        }
    }
    completionHandler()
}
```

---

## Summary

### New Files (2)
1. `Managers/BackendManager.swift` — API client
2. `Managers/KeychainHelper.swift` — Secure JWT storage

### Modified Files (6)
1. `GmailManager.swift` — Add serverClientID, capture refresh token
2. `OutlookManager.swift` — Pass refresh token to backend on sign-in
3. `AIManager.swift` — Route all AI calls through backend
4. `AppDelegate.swift` — Register APNs, forward device token
5. `InboxLedgerApp.swift` — Call registerForRemoteNotifications
6. `AppState.swift` — Sync settings changes to backend

### Remove After Backend Is Live
- `AIManager.swift` → Remove `openAIKey` and `anthropicKey` fields
- `ConnectedAccount.swift` → Remove `accessToken` property (backend handles tokens)
- `GmailManager.swift` → Remove `freshToken(for:)` (backend refreshes)
- `OutlookManager.swift` → Same
- `SlackManager.swift` → Remove `clientSecret` (move to backend env)
