// OutlookManager.swift
// Ledger
//
// Microsoft Outlook integration via Microsoft Graph API.
// Uses MSAL (Microsoft Authentication Library) for OAuth 2.0.
//
// BACKEND INTEGRATION:
// - signIn() now registers with the Ledger backend after MSAL auth
// - The backend stores tokens for server-side email fetching

import Foundation
import MSAL

struct OutlookSignInResult {
    let email: String
    let displayName: String
    let accessToken: String
}

final class OutlookManager {

    // ┌──────────────────────────────────────────────────────┐
    // │  REPLACE with your Azure App (Client) ID             │
    // └──────────────────────────────────────────────────────┘
    private let clientID = "b1095b3c-3ad2-4e65-94eb-5d361cd3e374"

    private let authority = "https://login.microsoftonline.com/common"
    private let redirectURI = "msauth.com.sendbird.educare.InboxLedger://auth"

    private let scopes = ["Mail.Read", "Mail.Send", "User.Read", "Chat.Read", "ChatMessage.Send", "Calendars.Read"]
    private let graphBaseURL = "https://graph.microsoft.com/v1.0/me"

    private var msalApp: MSALPublicClientApplication?
    private var msalAccounts: [String: MSALAccount] = [:]

    init() {
        setupMSAL()
    }

    private func setupMSAL() {
        do {
            let config = MSALPublicClientApplicationConfig(
                clientId: clientID,
                redirectUri: nil,
                authority: try MSALAuthority(url: URL(string: authority)!)
            )
            msalApp = try MSALPublicClientApplication(configuration: config)
            let defaultRedirect = config.redirectUri ?? "unknown"
            print("✅ MSAL configured. Computed redirect: \(defaultRedirect)")
        } catch {
            print("❌ MSAL setup failed: \(error)")
            do {
                let config = MSALPublicClientApplicationConfig(
                    clientId: clientID,
                    redirectUri: redirectURI,
                    authority: try MSALAuthority(url: URL(string: authority)!)
                )
                msalApp = try MSALPublicClientApplication(configuration: config)
                print("✅ MSAL configured with explicit redirect: \(redirectURI)")
            } catch {
                print("❌ MSAL fallback setup also failed: \(error)")
            }
        }
    }

    // MARK: - Sign In

    @MainActor
    func signIn() async throws -> OutlookSignInResult {
        guard let msalApp = msalApp else {
            throw OutlookError.msalNotConfigured
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            throw OutlookError.noRootViewController
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let webParams = MSALWebviewParameters(authPresentationViewController: topVC)
        let interactiveParams = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webParams)
        interactiveParams.promptType = .selectAccount

        do {
            print("🔄 MSAL: Starting acquireToken...")
            let result = try await msalApp.acquireToken(with: interactiveParams)
            print("✅ MSAL: acquireToken succeeded!")

            let email = result.account.username ?? ""
            let displayName = result.account.accountClaims?["name"] as? String ?? email

            msalAccounts[email] = result.account

            // Register with backend (non-blocking)
            let accessTokenCopy = result.accessToken
            Task.detached {
                do {
                    try await BackendManager.shared.register(
                        provider: "outlook", accessToken: accessTokenCopy,
                        refreshToken: "", email: email,
                        displayName: displayName, deviceToken: nil
                    )
                    print("✅ Outlook registered with backend: \(email)")
                } catch {
                    print("⚠️ Backend registration failed (non-fatal): \(error.localizedDescription)")
                }
            }

            print("✅ Outlook signed in: \(email)")
            return OutlookSignInResult(
                email: email,
                displayName: displayName,
                accessToken: result.accessToken
            )
        } catch let error as NSError {
            print("❌ MSAL error code: \(error.code), domain: \(error.domain)")
            print("❌ MSAL description: \(error.localizedDescription)")

            if let declined = error.userInfo["MSALDeclinedScopesKey"] {
                print("❌ MSAL DECLINED scopes: \(declined)")
            }
            if let granted = error.userInfo["MSALGrantedScopesKey"] {
                print("✅ MSAL GRANTED scopes: \(granted)")
            }
            if let invalidResult = error.userInfo["MSALInvalidResultKey"] as? MSALResult {
                let email = invalidResult.account.username ?? ""
                let displayName = invalidResult.account.accountClaims?["name"] as? String ?? email
                msalAccounts[email] = invalidResult.account

                // Register partial-consent result with backend too (non-blocking)
                let partialToken = invalidResult.accessToken
                Task.detached {
                    do {
                        try await BackendManager.shared.register(
                            provider: "outlook", accessToken: partialToken,
                            refreshToken: "", email: email,
                            displayName: displayName, deviceToken: nil
                        )
                    } catch {
                        print("⚠️ Backend registration failed (non-fatal): \(error.localizedDescription)")
                    }
                }

                print("⚠️ Partial consent — using token anyway for: \(email)")
                return OutlookSignInResult(
                    email: email,
                    displayName: displayName,
                    accessToken: invalidResult.accessToken
                )
            }
            if error.code == -50005 {
                throw OutlookError.userCancelled
            }
            throw error
        }
    }

    /// Silently refresh the access token for a specific account
    func refreshToken(for email: String) async throws -> String {
        guard let msalApp = msalApp else { throw OutlookError.msalNotConfigured }

        let account = msalAccounts[email] ?? (try? msalApp.allAccounts().first(where: { $0.username == email }))
        guard let msalAccount = account else { throw OutlookError.notSignedIn }

        let silentParams = MSALSilentTokenParameters(scopes: scopes, account: msalAccount)
        let result = try await msalApp.acquireTokenSilent(with: silentParams)
        msalAccounts[email] = result.account

        return result.accessToken
    }

    func refreshToken() async throws -> String {
        guard let email = msalAccounts.keys.first else { throw OutlookError.notSignedIn }
        return try await refreshToken(for: email)
    }

    func signOut(email: String) {
        guard let msalApp = msalApp,
              let account = msalAccounts[email] else { return }
        try? msalApp.remove(account)
        msalAccounts.removeValue(forKey: email)
    }

    func signOut() {
        guard let msalApp = msalApp else { return }
        for (_, account) in msalAccounts {
            try? msalApp.remove(account)
        }
        msalAccounts.removeAll()
    }

    // MARK: - Fetch Unread Messages

    func fetchRecentUnread(accessToken: String, since sinceOverride: Date? = nil, maxResults: Int = 40) async throws -> [LedgerEmail] {
        let since = sinceOverride ?? Date.sinceLastWindow
        let isoDate = ISO8601DateFormatter().string(from: since)

        let filter = "receivedDateTime ge \(isoDate)"
        let select = "id,conversationId,subject,bodyPreview,body,from,toRecipients,ccRecipients,receivedDateTime,isRead,internetMessageId"
        let query = "$filter=\(filter)&$select=\(select)&$top=\(maxResults)&$orderby=receivedDateTime desc"

        let urlString = "\(graphBaseURL)/messages?\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        let data = try await authenticatedGET(url: urlString, token: accessToken)

        let response = try JSONDecoder().decode(GraphMailResponse.self, from: data)

        return response.value.compactMap { msg -> LedgerEmail? in
            parseLedgerEmail(from: msg)
        }
    }

    // MARK: - Send Reply

    func sendReply(
        accessToken: String,
        messageId: String,
        body: String
    ) async throws {
        let url = "\(graphBaseURL)/messages/\(messageId)/reply"

        let payload: [String: Any] = [
            "message": [
                "body": [
                    "contentType": "Text",
                    "content": body
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OutlookError.sendFailed
        }
    }

    func sendReplyAll(
        accessToken: String,
        messageId: String,
        body: String
    ) async throws {
        let url = "\(graphBaseURL)/messages/\(messageId)/replyAll"

        let payload: [String: Any] = [
            "message": [
                "body": [
                    "contentType": "Text",
                    "content": body
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OutlookError.sendFailed
        }
    }

    // MARK: - Check if Still Unread

    func isMessageStillUnread(accessToken: String, messageId: String) async -> Bool {
        let url = "\(graphBaseURL)/messages/\(messageId)?$select=isRead"
        do {
            let data = try await authenticatedGET(url: url, token: accessToken)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let isRead = json?["isRead"] as? Bool {
                return !isRead
            }
            return true
        } catch {
            return true
        }
    }

    // MARK: - Signature

    func fetchSignature(accessToken: String) async -> String? {
        let url = "\(graphBaseURL)/mailboxSettings"
        do {
            let data = try await authenticatedGET(url: url, token: accessToken)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let sig = json["userPurpose"] as? String, !sig.isEmpty { return sig }
            return nil
        } catch {
            print("⚠️ Outlook signature fetch: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private Helpers

    func authenticatedGET(url: String, token: String, tokenRefresher: (() async -> String?)? = nil) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw OutlookError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401, let refresher = tokenRefresher {
                print("🔄 Outlook: 401 received, refreshing token and retrying...")
                if let newToken = await refresher() {
                    var retryRequest = URLRequest(url: requestURL)
                    retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    retryRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    guard let retryHttp = retryResponse as? HTTPURLResponse,
                          (200...299).contains(retryHttp.statusCode) else {
                        let code = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                        throw OutlookError.apiError(statusCode: code)
                    }
                    return retryData
                }
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ Outlook API error: HTTP \(httpResponse.statusCode) for \(url.prefix(80))")
                throw OutlookError.apiError(statusCode: httpResponse.statusCode)
            }
        }
        return data
    }

    // MARK: - Teams Chat: Fetch Recent Messages

    func fetchRecentTeamsChats(accessToken: String, since sinceOverride: Date? = nil, maxChats: Int = 20) async throws -> [LedgerEmail] {
        let chatsURL = "\(graphBaseURL)/chats?$expand=lastMessagePreview&$top=\(maxChats)&$orderby=lastMessagePreview/createdDateTime desc"
        let chatsData = try await authenticatedGET(url: chatsURL, token: accessToken)
        let chatsJson = try JSONSerialization.jsonObject(with: chatsData) as? [String: Any] ?? [:]
        let chats = chatsJson["value"] as? [[String: Any]] ?? []

        let since = sinceOverride ?? Date.sinceLastWindow
        var allMessages: [LedgerEmail] = []

        for chat in chats.prefix(15) {
            guard let chatId = chat["id"] as? String,
                  let preview = chat["lastMessagePreview"] as? [String: Any] else { continue }

            if let dateStr = preview["createdDateTime"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: dateStr), date < since { continue }
            }

            let msgsURL = "\(graphBaseURL)/chats/\(chatId)/messages?$top=5&$orderby=createdDateTime desc"
            guard let msgsData = try? await authenticatedGET(url: msgsURL, token: accessToken),
                  let msgsJson = try? JSONSerialization.jsonObject(with: msgsData) as? [String: Any],
                  let messages = msgsJson["value"] as? [[String: Any]] else { continue }

            for msg in messages {
                guard let msgType = msg["messageType"] as? String, msgType == "message" else { continue }
                guard let msgId = msg["id"] as? String else { continue }

                let from = msg["from"] as? [String: Any] ?? [:]
                let user = from["user"] as? [String: Any] ?? [:]

                let senderName = user["displayName"] as? String ?? "Unknown"
                let senderId = user["id"] as? String ?? ""

                let bodyObj = msg["body"] as? [String: Any] ?? [:]
                let contentType = bodyObj["contentType"] as? String ?? ""
                let rawContent = bodyObj["content"] as? String ?? ""

                let body: String
                if contentType.lowercased() == "html" {
                    body = rawContent
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    body = rawContent
                }

                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let dateStr = msg["createdDateTime"] as? String ?? ""
                let date = formatter.date(from: dateStr) ?? Date()
                if date < since { continue }

                let chatTopic = chat["topic"] as? String ?? ""

                let item = LedgerEmail(
                    id: "teams_\(chatId)_\(msgId)",
                    source: .teams,
                    threadId: chatId,
                    messageId: msgId,
                    senderName: senderName,
                    senderEmail: senderId,
                    subject: chatTopic,
                    snippet: String(body.prefix(100)),
                    body: body,
                    date: date,
                    isUnread: true
                )
                allMessages.append(item)
            }
        }

        return allMessages
    }

    // MARK: - Teams Chat: Send Reply

    func sendTeamsChatMessage(
        accessToken: String,
        chatId: String,
        text: String
    ) async throws {
        let url = "\(graphBaseURL)/chats/\(chatId)/messages"

        let payload: [String: Any] = [
            "body": [
                "content": text,
                "contentType": "text"
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OutlookError.sendFailed
        }
    }

    private func parseLedgerEmail(from msg: GraphMessage) -> LedgerEmail? {
        let senderName = msg.from?.emailAddress?.name ?? "Unknown"
        let senderEmail = msg.from?.emailAddress?.address ?? ""

        let toRecipients = msg.toRecipients?.compactMap { $0.emailAddress?.address } ?? []
        let ccRecipients = msg.ccRecipients?.compactMap { $0.emailAddress?.address } ?? []

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: msg.receivedDateTime ?? "") ?? Date()

        let body: String
        if msg.body?.contentType?.lowercased() == "text" {
            body = msg.body?.content ?? msg.bodyPreview ?? ""
        } else {
            body = (msg.body?.content ?? msg.bodyPreview ?? "")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let links = LinkDetector.shared.detectLinks(in: body)

        return LedgerEmail(
            id: msg.id,
            source: .outlook,
            threadId: msg.conversationId ?? "",
            messageId: msg.internetMessageId ?? msg.id,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: msg.subject ?? "(No Subject)",
            snippet: msg.bodyPreview ?? "",
            body: body,
            date: date,
            isUnread: !(msg.isRead ?? false),
            toRecipients: toRecipients,
            ccRecipients: ccRecipients,
            detectedLinks: links
        )
    }

    func fetchAttachments(messageId: String, accessToken: String) async -> [EmailAttachment] {
        let urlStr = "\(graphBaseURL)/messages/\(messageId)/attachments?$select=id,name,contentType,size,isInline"
        guard let url = URL(string: urlStr) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(GraphAttachmentResponse.self, from: data)
            return response.value.map { att in
                EmailAttachment(
                    id: att.id,
                    filename: att.name ?? "attachment",
                    mimeType: att.contentType ?? "application/octet-stream",
                    size: att.size ?? 0,
                    isInline: att.isInline ?? false
                )
            }
        } catch {
            print("⚠️ Failed to fetch Outlook attachments: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Outlook Attachment Response

struct GraphAttachmentResponse: Codable {
    let value: [GraphAttachment]
}

struct GraphAttachment: Codable {
    let id: String
    let name: String?
    let contentType: String?
    let size: Int?
    let isInline: Bool?
}

// MARK: - Errors

enum OutlookError: LocalizedError {
    case msalNotConfigured
    case noRootViewController
    case notSignedIn
    case userCancelled
    case invalidURL
    case apiError(statusCode: Int)
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .msalNotConfigured: return "MSAL not configured"
        case .noRootViewController: return "Cannot present sign-in"
        case .notSignedIn: return "Not signed into Outlook"
        case .userCancelled: return nil
        case .invalidURL: return "Invalid URL"
        case .apiError(let c): return "Microsoft Graph API error \(c)"
        case .sendFailed: return "Failed to send reply"
        }
    }
}

// MARK: - Microsoft Graph API Response Models

struct GraphMailResponse: Codable {
    let value: [GraphMessage]
}

struct GraphMessage: Codable {
    let id: String
    let conversationId: String?
    let internetMessageId: String?
    let subject: String?
    let bodyPreview: String?
    let body: GraphBody?
    let from: GraphRecipient?
    let toRecipients: [GraphRecipient]?
    let ccRecipients: [GraphRecipient]?
    let receivedDateTime: String?
    let isRead: Bool?
    let hasAttachments: Bool?
}

struct GraphBody: Codable {
    let contentType: String?
    let content: String?
}

struct GraphRecipient: Codable {
    let emailAddress: GraphEmailAddress?
}

struct GraphEmailAddress: Codable {
    let name: String?
    let address: String?
}

// MARK: - Mark as Read/Unread

extension OutlookManager {

    func markAsRead(messageId: String, accessToken: String) async throws {
        let urlStr = "\(graphBaseURL)/messages/\(messageId)"
        guard let url = URL(string: urlStr) else { throw OutlookError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["isRead": true])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("⚠️ Outlook markAsRead failed for \(messageId)")
            return
        }
        print("✅ Outlook: marked \(messageId) as read")
    }

    func markAsUnread(messageId: String, accessToken: String) async throws {
        let urlStr = "\(graphBaseURL)/messages/\(messageId)"
        guard let url = URL(string: urlStr) else { throw OutlookError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["isRead": false])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("⚠️ Outlook markAsUnread failed for \(messageId)")
            return
        }
        print("✅ Outlook: marked \(messageId) as unread")
    }
}
