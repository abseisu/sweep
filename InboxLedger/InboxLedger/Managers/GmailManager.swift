// GmailManager.swift
// Inbox Ledger
//
// Handles Google Sign-In (OAuth 2.0) and Gmail REST API calls.
// Uses raw URLSession — no Google Client Library needed.
//
// BACKEND INTEGRATION:
// - signIn() now captures serverAuthCode and registers with the backend
// - The backend stores refresh tokens and can fetch emails independently for push notifications

import Foundation
import GoogleSignIn

// MARK: - Sign-In Result

struct SignInResult {
    let email: String
    let displayName: String
    let accessToken: String
    let serverAuthCode: String?   // For backend token exchange
}

// MARK: - Gmail Manager

final class GmailManager {

    // ┌──────────────────────────────────────────────┐
    // │  Your iOS OAuth Client ID                     │
    // └──────────────────────────────────────────────┘
    private let clientID = "697711459258-8j5nlimlhvvr7l38s7d57on88m1ptoph.apps.googleusercontent.com"

    // ┌──────────────────────────────────────────────┐
    // │  Your Web Application Client ID (from         │
    // │  Google Cloud Console — the one with a        │
    // │  client secret). Needed to get serverAuthCode │
    // │  for backend token exchange.                  │
    // └──────────────────────────────────────────────┘
    private let serverClientID = "697711459258-7scr5lbsbp808dqei4uscdfs2ad047jb.apps.googleusercontent.com"  // TODO: Replace with actual web client ID

    private let gmailBaseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    private let requiredScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/calendar.readonly"
    ]

    /// Per-account GIDGoogleUser references — supports multiple Gmail accounts.
    /// GIDSignIn.sharedInstance only tracks one "current" user, so we cache all users here.
    private var usersByEmail: [String: GIDGoogleUser] = [:]

    // MARK: - Sign In

    @MainActor
    func signIn() async throws -> SignInResult {
        // Configure Google Sign-In with BOTH client IDs
        let config = GIDConfiguration(clientID: clientID, serverClientID: serverClientID)
        GIDSignIn.sharedInstance.configuration = config

        // NOTE: Do NOT call disconnect() here — it destroys the keychain session
        // and prevents restorePreviousSignIn from working on next app launch.
        // If you need the account picker, use signIn(hint: nil) instead.

        // Get the topmost view controller
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            throw GmailError.noRootViewController
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // Perform sign-in with Gmail scopes
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: topVC,
            hint: nil,
            additionalScopes: requiredScopes
        )

        // Extract the access token
        guard let accessToken = result.user.accessToken.tokenString as String? else {
            throw GmailError.noAccessToken
        }

        let email = result.user.profile?.email ?? "unknown"
        let name = result.user.profile?.name ?? "User"
        let serverAuthCode = result.serverAuthCode

        // Cache the user object for this account — enables per-account token refresh
        usersByEmail[email] = result.user

        // Register with the Ledger backend (non-blocking — don't slow down sign-in)
        Task.detached {
            do {
                try await BackendManager.shared.register(
                    provider: "gmail",
                    accessToken: accessToken,
                    refreshToken: serverAuthCode ?? "",
                    email: email,
                    displayName: name,
                    deviceToken: nil
                )
                print("✅ Gmail registered with backend: \(email)")
            } catch {
                print("⚠️ Backend registration failed (non-fatal): \(error.localizedDescription)")
            }
        }

        return SignInResult(
            email: email,
            displayName: name,
            accessToken: accessToken,
            serverAuthCode: serverAuthCode
        )
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        usersByEmail.removeAll()
    }

    /// Refreshes the access token for a specific Gmail account by email.
    /// Uses the per-account cached GIDGoogleUser, falling back to the shared instance.
    ///
    /// Multi-account note: Google Sign-In SDK only stores ONE user in the keychain.
    /// For the second account, we rely on the in-memory GIDGoogleUser cached during signIn().
    /// If the app is killed, only the last-signed-in account can be restored from keychain.
    /// The other account's token will be stale but still usable until it expires (~60 min).
    func refreshToken(for email: String) async throws -> String? {
        // 1. Try per-account cached user (works for ALL accounts while app is alive)
        if let user = usersByEmail[email] {
            do {
                try await user.refreshTokensIfNeeded()
                if let token = user.accessToken.tokenString as String?, !token.isEmpty {
                    print("🔄 Gmail token refreshed for \(email)")
                    return token
                }
            } catch {
                print("⚠️ Gmail: cached user refresh failed for \(email): \(error.localizedDescription)")
                // Don't return nil yet — try keychain fallback
            }
        }

        // 2. Try restoring from keychain (only works for last signed-in user)
        if let result = try await restoreSession() {
            // Cache whatever account was restored
            if let user = GIDSignIn.sharedInstance.currentUser, !result.email.isEmpty {
                usersByEmail[result.email] = user
            }
            if result.email == email {
                return result.accessToken
            }
            // Restored a different account — can't help this one
            print("⚠️ Gmail: keychain restored \(result.email), not \(email)")
        }

        print("⚠️ Gmail: could not refresh token for \(email) — user may need to re-sign in")
        return nil
    }

    /// Restores the Google Sign-In session from the keychain (cold start).
    /// Only restores the LAST signed-in user (Google SDK limitation).
    func restoreSession() async throws -> SignInResult? {
        if GIDSignIn.sharedInstance.currentUser == nil {
            do {
                try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                print("✅ Gmail: restored session from keychain")
            } catch {
                print("⚠️ Gmail: restorePreviousSignIn failed: \(error.localizedDescription)")
                return nil
            }
        }

        guard let user = GIDSignIn.sharedInstance.currentUser else {
            return nil
        }

        do {
            try await user.refreshTokensIfNeeded()
        } catch {
            print("⚠️ Gmail: token refresh failed, retrying: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                try await GIDSignIn.sharedInstance.currentUser?.refreshTokensIfNeeded()
            } catch {
                print("❌ Gmail: re-auth failed: \(error.localizedDescription)")
                return nil
            }
        }

        guard let freshUser = GIDSignIn.sharedInstance.currentUser,
              let token = freshUser.accessToken.tokenString as String?, !token.isEmpty else {
            return nil
        }

        let email = freshUser.profile?.email ?? ""
        if !email.isEmpty {
            usersByEmail[email] = freshUser
        }

        return SignInResult(
            email: email,
            displayName: freshUser.profile?.name ?? "",
            accessToken: token,
            serverAuthCode: nil
        )
    }

    // MARK: - Fetch Recent Emails (Last 24 Hours — read AND unread)

    func fetchRecentUnread(accessToken: String, since sinceOverride: Date? = nil, maxResults: Int = 40, tokenRefresher: (() async -> String?)? = nil) async throws -> [LedgerEmail] {
        let since = sinceOverride ?? Date.sinceLastWindow
        let epochSeconds = Int(since.timeIntervalSince1970)

        // Use the provided token — caller (freshToken) already refreshed it.
        // The tokenRefresher is kept only as a 401-retry fallback.
        let token = accessToken

        // Fetch ALL inbox emails (not just unread)
        let query = "in:inbox after:\(epochSeconds)"
        print("📧 Gmail query: \(query) (since: \(since), maxResults: \(maxResults))")

        // Step 1: List message IDs
        let listURL = "\(gmailBaseURL)/messages?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&maxResults=\(maxResults)"
        let listData = try await authenticatedGET(url: listURL, token: token, tokenRefresher: tokenRefresher)
        let listResponse = try JSONDecoder().decode(GmailListResponse.self, from: listData)

        guard let messageRefs = listResponse.messages, !messageRefs.isEmpty else {
            print("📧 Gmail: 0 messages matched query")
            return []
        }

        print("📧 Gmail: \(messageRefs.count) message IDs returned")

        // Step 2: Fetch thread IDs of messages the user has SENT recently
        let repliedThreadIds = await fetchRepliedThreadIds(accessToken: token, since: epochSeconds, tokenRefresher: tokenRefresher)

        // Step 3: Fetch full message details for each ID
        var emails: [LedgerEmail] = []

        for ref in messageRefs {
            let detailURL = "\(gmailBaseURL)/messages/\(ref.id)?format=full"
            let detailData = try await authenticatedGET(url: detailURL, token: token, tokenRefresher: tokenRefresher)
            let message = try JSONDecoder().decode(GmailMessage.self, from: detailData)

            if var email = parseLedgerEmail(from: message) {
                email.userHasReplied = repliedThreadIds.contains(message.threadId)
                emails.append(email)
            }
        }

        return emails
    }

    /// Fetches thread IDs where the user has sent a message recently
    private func fetchRepliedThreadIds(accessToken: String, since epochSeconds: Int, tokenRefresher: (() async -> String?)? = nil) async -> Set<String> {
        let query = "in:sent after:\(epochSeconds)"
        let url = "\(gmailBaseURL)/messages?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&maxResults=50"

        do {
            let data = try await authenticatedGET(url: url, token: accessToken, tokenRefresher: tokenRefresher)
            let response = try JSONDecoder().decode(GmailListResponse.self, from: data)
            guard let refs = response.messages else { return [] }

            var threadIds = Set<String>()
            for ref in refs {
                let detailURL = "\(gmailBaseURL)/messages/\(ref.id)?format=metadata&metadataHeaders=Subject"
                if let detailData = try? await authenticatedGET(url: detailURL, token: accessToken, tokenRefresher: tokenRefresher),
                   let msg = try? JSONDecoder().decode(GmailMessage.self, from: detailData) {
                    threadIds.insert(msg.threadId)
                }
            }
            return threadIds
        } catch {
            print("⚠️ Gmail: couldn't fetch sent messages: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Check if Thread Still Needs Reply

    func isMessageStillUnread(accessToken: String, messageId: String) async -> Bool {
        let url = "\(gmailBaseURL)/messages/\(messageId)?format=metadata&metadataHeaders=From"
        do {
            let data = try await authenticatedGET(url: url, token: accessToken)
            let message = try JSONDecoder().decode(GmailMessage.self, from: data)
            return message.labelIds?.contains("UNREAD") ?? false
        } catch {
            return true
        }
    }

    // MARK: - Send Reply

    func sendReply(
        accessToken: String,
        fromName: String?,
        fromEmail: String?,
        to: String,
        subject: String,
        body: String,
        threadId: String,
        messageId: String
    ) async throws {
        let fromHeader: String?
        if let name = fromName, let email = fromEmail {
            fromHeader = "\(name) <\(email)>"
        } else {
            fromHeader = nil
        }
        let rawMessage = buildRawRFC2822(
            from: fromHeader,
            to: to,
            cc: nil,
            subject: subject,
            body: body,
            inReplyTo: messageId,
            references: messageId
        )
        try await sendRaw(accessToken: accessToken, raw: rawMessage, threadId: threadId)
    }

    /// Send a reply-all with To and CC
    func sendReplyAll(
        accessToken: String,
        fromName: String?,
        fromEmail: String?,
        to: [String],
        cc: [String],
        subject: String,
        body: String,
        threadId: String,
        messageId: String
    ) async throws {
        let fromHeader: String?
        if let name = fromName, let email = fromEmail {
            fromHeader = "\(name) <\(email)>"
        } else {
            fromHeader = nil
        }
        let rawMessage = buildRawRFC2822(
            from: fromHeader,
            to: to.joined(separator: ", "),
            cc: cc.isEmpty ? nil : cc.joined(separator: ", "),
            subject: subject,
            body: body,
            inReplyTo: messageId,
            references: messageId
        )
        try await sendRaw(accessToken: accessToken, raw: rawMessage, threadId: threadId)
    }

    private func sendRaw(accessToken: String, raw: String, threadId: String) async throws {
        guard let messageData = raw.data(using: .utf8) else {
            throw GmailError.encodingFailed
        }
        let base64url = messageData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let sendURL = "\(gmailBaseURL)/messages/send"
        let payload: [String: Any] = [
            "raw": base64url,
            "threadId": threadId
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: sendURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GmailError.sendFailed
        }
    }

    // MARK: - Signature

    func fetchSignature(accessToken: String, email: String) async -> String? {
        let url = "\(gmailBaseURL)/settings/sendAs/\(email)"
        do {
            let data = try await authenticatedGET(url: url, token: accessToken)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let htmlSig = json["signature"] as? String, !htmlSig.isEmpty else { return nil }
            return htmlToPlainText(htmlSig)
        } catch {
            print("⚠️ Gmail signature fetch: \(error.localizedDescription)")
            return nil
        }
    }

    private func htmlToPlainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else {
            return html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
                       .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    /// Authenticated GET with automatic retry on 401 (expired token).
    func authenticatedGET(url: String, token: String, tokenRefresher: (() async -> String?)? = nil) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw GmailError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401, let refresher = tokenRefresher {
                print("🔄 Gmail: 401 received, refreshing token and retrying...")
                if let newToken = await refresher() {
                    var retryRequest = URLRequest(url: requestURL)
                    retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    guard let retryHttp = retryResponse as? HTTPURLResponse,
                          (200...299).contains(retryHttp.statusCode) else {
                        print("❌ Gmail: retry also failed with \((retryResponse as? HTTPURLResponse)?.statusCode ?? -1)")
                        throw GmailError.fetchFailed
                    }
                    return retryData
                }
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ Gmail API error: HTTP \(httpResponse.statusCode) for \(url.prefix(80))")
                throw GmailError.fetchFailed
            }
        }
        return data
    }

    private func parseLedgerEmail(from message: GmailMessage) -> LedgerEmail? {
        let headers = message.payload?.headers ?? []

        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? "(No Subject)"
        let from = headers.first { $0.name.lowercased() == "from" }?.value ?? ""
        let dateStr = headers.first { $0.name.lowercased() == "date" }?.value ?? ""
        let msgId = headers.first { $0.name.lowercased() == "message-id" }?.value ?? ""

        let (senderName, senderEmail) = parseFromHeader(from)
        let date = parseEmailDate(dateStr)
        let body = extractPlainTextBody(from: message.payload)
        let isUnread = message.labelIds?.contains("UNREAD") ?? false

        let toHeader = headers.first { $0.name.lowercased() == "to" }?.value ?? ""
        let ccHeader = headers.first { $0.name.lowercased() == "cc" }?.value ?? ""
        let toRecipients = parseRecipientList(toHeader)
        let ccRecipients = parseRecipientList(ccHeader)

        let attachments = extractAttachments(from: message.payload)
        let links = LinkDetector.shared.detectLinks(in: body)

        return LedgerEmail(
            id: message.id,
            source: .gmail,
            threadId: message.threadId,
            messageId: msgId,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            snippet: message.snippet ?? "",
            body: body,
            date: date,
            isUnread: isUnread,
            toRecipients: toRecipients,
            ccRecipients: ccRecipients,
            attachments: attachments,
            detectedLinks: links
        )
    }

    private func extractAttachments(from payload: GmailPayload?) -> [EmailAttachment] {
        guard let payload = payload else { return [] }
        var results: [EmailAttachment] = []

        if let filename = payload.filename, !filename.isEmpty,
           let attachmentId = payload.body?.attachmentId {
            let size = payload.body?.size ?? 0
            let mimeType = payload.mimeType ?? "application/octet-stream"

            let contentId = payload.headers?.first { $0.name.lowercased() == "content-id" }?.value
            let disposition = payload.headers?.first { $0.name.lowercased() == "content-disposition" }?.value ?? ""
            let isInline = contentId != nil || disposition.lowercased().hasPrefix("inline")

            results.append(EmailAttachment(
                id: attachmentId,
                filename: filename,
                mimeType: mimeType,
                size: size,
                isInline: isInline
            ))
        }

        if let parts = payload.parts {
            for part in parts {
                results.append(contentsOf: extractAttachments(from: part))
            }
        }

        return results
    }

    private func parseFromHeader(_ from: String) -> (String, String) {
        if let angleStart = from.firstIndex(of: "<"),
           let angleEnd = from.firstIndex(of: ">") {
            let name = String(from[from.startIndex..<angleStart]).trimmingCharacters(in: .whitespaces)
            let email = String(from[from.index(after: angleStart)..<angleEnd])
            return (name.isEmpty ? email : name, email)
        }
        return (from, from)
    }

    private func extractPlainTextBody(from payload: GmailPayload?) -> String {
        guard let payload = payload else { return "" }

        if payload.mimeType == "text/plain",
           let bodyData = payload.body?.data {
            return decodeBase64URL(bodyData)
        }

        if let parts = payload.parts {
            for part in parts {
                let text = extractPlainTextBody(from: part)
                if !text.isEmpty { return text }
            }
        }

        if let bodyData = payload.body?.data, !bodyData.isEmpty {
            return decodeBase64URL(bodyData)
        }

        return ""
    }

    private func decodeBase64URL(_ string: String) -> String {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64 += "="
        }

        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private func parseEmailDate(_ dateString: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss z",
            "EEE, dd MMM yyyy HH:mm:ss Z (z)"
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return Date()
    }

    private func buildRawRFC2822(
        from: String?,
        to: String,
        cc: String?,
        subject: String,
        body: String,
        inReplyTo: String,
        references: String
    ) -> String {
        var headers = ""
        if let from = from {
            headers += "From: \(from)\n"
        }
        headers += "To: \(to)\n"
        headers += "Subject: \(subject)\n"
        headers += "In-Reply-To: \(inReplyTo)\n"
        headers += "References: \(references)\n"
        if let cc = cc {
            headers += "Cc: \(cc)\n"
        }
        headers += "Content-Type: text/plain; charset=\"UTF-8\"\n"
        headers += "MIME-Version: 1.0\n"
        headers += "\n"
        headers += body
        return headers
    }

    private func parseRecipientList(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return raw
            .components(separatedBy: ",")
            .compactMap { part -> String? in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if let start = trimmed.firstIndex(of: "<"),
                   let end = trimmed.firstIndex(of: ">") {
                    return String(trimmed[trimmed.index(after: start)..<end])
                }
                if trimmed.contains("@") { return trimmed }
                return nil
            }
    }
}

// MARK: - Gmail API Response Models

struct GmailListResponse: Codable {
    let messages: [GmailMessageRef]?
    let resultSizeEstimate: Int?
}

struct GmailMessageRef: Codable {
    let id: String
    let threadId: String
}

struct GmailMessage: Codable {
    let id: String
    let threadId: String
    let snippet: String?
    let labelIds: [String]?
    let payload: GmailPayload?
}

struct GmailPayload: Codable {
    let mimeType: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPayload]?
    let filename: String?
}

struct GmailHeader: Codable {
    let name: String
    let value: String
}

struct GmailBody: Codable {
    let size: Int?
    let data: String?
    let attachmentId: String?
}

// MARK: - Mark as Read/Unread

extension GmailManager {

    func markAsRead(messageId: String, accessToken: String) async throws {
        let urlStr = "\(gmailBaseURL)/messages/\(messageId)/modify"
        guard let url = URL(string: urlStr) else { throw GmailError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["removeLabelIds": ["UNREAD"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("⚠️ Gmail markAsRead failed for \(messageId)")
            return
        }
        print("✅ Gmail: marked \(messageId) as read")
    }

    func markAsUnread(messageId: String, accessToken: String) async throws {
        let urlStr = "\(gmailBaseURL)/messages/\(messageId)/modify"
        guard let url = URL(string: urlStr) else { throw GmailError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["addLabelIds": ["UNREAD"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("⚠️ Gmail markAsUnread failed for \(messageId)")
            return
        }
        print("✅ Gmail: marked \(messageId) as unread")
    }
}

// MARK: - Errors

enum GmailError: LocalizedError {
    case noRootViewController
    case noAccessToken
    case invalidURL
    case fetchFailed
    case sendFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noRootViewController: return "Cannot find root view controller"
        case .noAccessToken:        return "Failed to obtain access token"
        case .invalidURL:           return "Invalid API URL"
        case .fetchFailed:          return "Failed to fetch emails"
        case .sendFailed:           return "Failed to send reply"
        case .encodingFailed:       return "Failed to encode message"
        }
    }
}

