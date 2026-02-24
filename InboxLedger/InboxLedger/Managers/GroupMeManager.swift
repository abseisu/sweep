// GroupMeManager.swift
// Ledger
//
// GroupMe integration via GroupMe API.
// Focuses on DMs and group messages where user is @mentioned.
//
// SETUP:
// 1. Go to https://dev.groupme.com → Sign in → Access Token (top right)
//    Copy your access token — that's it, no OAuth flow needed.
// 2. Paste the token when connecting in the app.
//
// GroupMe uses a simple token-based auth. Each user has a persistent
// developer token that gives full access to their account.

import Foundation
import AuthenticationServices

struct GroupMeSignInResult {
    let userId: String
    let displayName: String
    let accessToken: String
}

final class GroupMeManager: NSObject {

    private let baseURL = "https://api.groupme.com/v3"

    // MARK: - Sign In

    /// GroupMe uses a developer token. We'll present a simple prompt for it,
    /// but also support the OAuth flow via ASWebAuthenticationSession.
    @MainActor
    func signIn() async throws -> GroupMeSignInResult {
        // Use OAuth flow
        let token = try await authenticateWithOAuth()

        // Verify token by fetching current user
        guard let url = URL(string: "\(baseURL)/users/me?token=\(token)") else {
            throw GroupMeError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GroupMeError.authFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resp = json?["response"] as? [String: Any]
        let userId = resp?["user_id"] as? String ?? resp?["id"] as? String ?? ""
        let name = resp?["name"] as? String ?? "GroupMe User"

        return GroupMeSignInResult(userId: userId, displayName: name, accessToken: token)
    }

    @MainActor
    private func authenticateWithOAuth() async throws -> String {
        // GroupMe OAuth: redirect user to authorize, get token back
        // Client ID is registered at https://dev.groupme.com/applications
        let clientID = "YOUR_GROUPME_CLIENT_ID"  // Replace with your app's client ID

        let authURL = "https://oauth.groupme.com/oauth/authorize?client_id=\(clientID)"
        let callbackScheme = "ledger"

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: URL(string: authURL)!,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = callbackURL,
                      let fragment = url.fragment,
                      let token = fragment.components(separatedBy: "=").last else {
                    continuation.resume(throwing: GroupMeError.authFailed)
                    return
                }
                continuation.resume(returning: token)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            session.start()
        }
    }

    // MARK: - Fetch DMs

    /// Fetches recent direct messages (1:1 conversations).
    func fetchDirectMessages(accessToken: String, since: Date? = nil) async throws -> [LedgerEmail] {
        // 1. Get list of DM chats
        guard let chatsURL = URL(string: "\(baseURL)/chats?token=\(accessToken)&per_page=20") else {
            throw GroupMeError.invalidURL
        }

        let (chatsData, chatsResp) = try await URLSession.shared.data(from: chatsURL)
        guard let chatsHttp = chatsResp as? HTTPURLResponse, (200...299).contains(chatsHttp.statusCode) else {
            throw GroupMeError.fetchFailed
        }

        let chatsJson = try JSONSerialization.jsonObject(with: chatsData) as? [String: Any]
        let chats = chatsJson?["response"] as? [[String: Any]] ?? []

        // Get current user ID to filter out our own messages
        let myUserId = try await getCurrentUserId(accessToken: accessToken)

        var items: [LedgerEmail] = []

        for chat in chats.prefix(10) {
            let otherUser = chat["other_user"] as? [String: Any] ?? [:]
            let otherName = otherUser["name"] as? String ?? "Unknown"
            let otherId = otherUser["id"] as? String ?? ""

            let lastMessage = chat["last_message"] as? [String: Any] ?? [:]
            let senderId = lastMessage["sender_id"] as? String ?? ""
            let text = lastMessage["text"] as? String ?? ""
            let messageId = lastMessage["id"] as? String ?? ""
            let createdAt = lastMessage["created_at"] as? TimeInterval ?? 0
            let messageDate = Date(timeIntervalSince1970: createdAt)

            // Skip messages from us
            guard senderId != myUserId else { continue }

            // Skip old messages (24h default)
            let cutoff = since ?? Date().addingTimeInterval(-86400)
            guard messageDate > cutoff else { continue }

            // Skip empty
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            items.append(LedgerEmail(
                id: "gm_dm_\(messageId)",
                source: .groupme,
                threadId: otherId,
                messageId: messageId,
                senderName: otherName,
                senderEmail: otherId,
                subject: "Direct Message",
                snippet: String(text.prefix(100)),
                body: text,
                date: messageDate,
                isUnread: true
            ))
        }

        return items
    }

    // MARK: - Fetch @Mentions in Groups

    /// Fetches group messages where the user is @mentioned.
    func fetchMentions(accessToken: String, since: Date? = nil) async throws -> [LedgerEmail] {
        // 1. Get groups
        guard let groupsURL = URL(string: "\(baseURL)/groups?token=\(accessToken)&per_page=20&omit=memberships") else {
            throw GroupMeError.invalidURL
        }

        let (groupsData, groupsResp) = try await URLSession.shared.data(from: groupsURL)
        guard let groupsHttp = groupsResp as? HTTPURLResponse, (200...299).contains(groupsHttp.statusCode) else {
            throw GroupMeError.fetchFailed
        }

        let groupsJson = try JSONSerialization.jsonObject(with: groupsData) as? [String: Any]
        let groups = groupsJson?["response"] as? [[String: Any]] ?? []

        let myUserId = try await getCurrentUserId(accessToken: accessToken)
        let cutoff = since ?? Date().addingTimeInterval(-86400)

        var items: [LedgerEmail] = []

        for group in groups.prefix(15) {
            let groupId = group["group_id"] as? String ?? group["id"] as? String ?? ""
            let groupName = group["name"] as? String ?? "Group"

            // Fetch recent messages for this group
            guard let msgsURL = URL(string: "\(baseURL)/groups/\(groupId)/messages?token=\(accessToken)&limit=20") else {
                continue
            }

            guard let (msgsData, msgsResp) = try? await URLSession.shared.data(from: msgsURL),
                  let msgsHttp = msgsResp as? HTTPURLResponse, (200...299).contains(msgsHttp.statusCode) else {
                continue
            }

            let msgsJson = try? JSONSerialization.jsonObject(with: msgsData) as? [String: Any]
            let msgsResponse = msgsJson?["response"] as? [String: Any]
            let messages = msgsResponse?["messages"] as? [[String: Any]] ?? []

            for msg in messages {
                let senderId = msg["sender_id"] as? String ?? ""
                guard senderId != myUserId else { continue }

                let createdAt = msg["created_at"] as? TimeInterval ?? 0
                let messageDate = Date(timeIntervalSince1970: createdAt)
                guard messageDate > cutoff else { continue }

                let text = msg["text"] as? String ?? ""
                let senderName = msg["name"] as? String ?? "Unknown"
                let messageId = msg["id"] as? String ?? ""

                // Check for @mentions
                let attachments = msg["attachments"] as? [[String: Any]] ?? []
                let isMentioned = attachments.contains { attachment in
                    guard attachment["type"] as? String == "mentions" else { return false }
                    let userIds = attachment["user_ids"] as? [String] ?? []
                    return userIds.contains(myUserId)
                }

                guard isMentioned else { continue }

                items.append(LedgerEmail(
                    id: "gm_grp_\(messageId)",
                    source: .groupme,
                    threadId: groupId,
                    messageId: messageId,
                    senderName: senderName,
                    senderEmail: senderId,
                    subject: "@ in \(groupName)",
                    snippet: String(text.prefix(100)),
                    body: text,
                    date: messageDate,
                    isUnread: true
                ))
            }
        }

        return items
    }

    // MARK: - Fetch All (DMs + Mentions)

    func fetchRecentMessages(accessToken: String, since: Date? = nil) async throws -> [LedgerEmail] {
        async let dms = fetchDirectMessages(accessToken: accessToken, since: since)
        async let mentions = fetchMentions(accessToken: accessToken, since: since)

        let allItems = try await dms + (try await mentions)
        print("📬 GroupMe: \(allItems.count) items (DMs + @mentions)")
        return allItems
    }

    // MARK: - Send Reply

    /// Send a DM reply to a user.
    func sendDirectMessage(accessToken: String, recipientId: String, text: String) async throws {
        guard let url = URL(string: "\(baseURL)/direct_messages?token=\(accessToken)") else {
            throw GroupMeError.invalidURL
        }

        let sourceGUID = UUID().uuidString

        let body: [String: Any] = [
            "direct_message": [
                "recipient_id": recipientId,
                "text": text,
                "source_guid": sourceGUID
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GroupMeError.sendFailed
        }
        print("✅ GroupMe: sent DM to \(recipientId)")
    }

    /// Send a reply to a group.
    func sendGroupMessage(accessToken: String, groupId: String, text: String) async throws {
        guard let url = URL(string: "\(baseURL)/groups/\(groupId)/messages?token=\(accessToken)") else {
            throw GroupMeError.invalidURL
        }

        let sourceGUID = UUID().uuidString

        let body: [String: Any] = [
            "message": [
                "text": text,
                "source_guid": sourceGUID
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GroupMeError.sendFailed
        }
        print("✅ GroupMe: sent message to group \(groupId)")
    }

    // MARK: - Helpers

    private var cachedUserId: String?

    private func getCurrentUserId(accessToken: String) async throws -> String {
        if let cached = cachedUserId { return cached }

        guard let url = URL(string: "\(baseURL)/users/me?token=\(accessToken)") else {
            throw GroupMeError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GroupMeError.fetchFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resp = json?["response"] as? [String: Any]
        let userId = resp?["user_id"] as? String ?? resp?["id"] as? String ?? ""
        cachedUserId = userId
        return userId
    }
}

// MARK: - ASWebAuthenticationSession

extension GroupMeManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Errors

enum GroupMeError: LocalizedError {
    case invalidURL
    case authFailed
    case fetchFailed
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .authFailed: return "GroupMe authentication failed"
        case .fetchFailed: return "Failed to fetch GroupMe messages"
        case .sendFailed: return "Failed to send GroupMe message"
        }
    }
}
