// SlackManager.swift
// Ledger
//
// Slack integration via Slack Web API + OAuth 2.0.
//
// SETUP:
// 1. Go to https://api.slack.com/apps → Create New App → From scratch
// 2. App Name: "Ledger", pick your workspace
// 3. OAuth & Permissions → Add scopes:
//    - channels:history, channels:read, groups:history, groups:read
//    - im:history, im:read, mpim:history, mpim:read
//    - chat:write, users:read
// 4. Install to Workspace → copy the Bot User OAuth Token
// 5. Also get a User OAuth Token (for reading your DMs):
//    - Add User Token Scopes: channels:history, groups:history, im:history, mpim:history
//    - Reinstall app → copy User OAuth Token
// 6. Paste the User OAuth Token below (starts with xoxp-)

import Foundation
import AuthenticationServices

struct SlackSignInResult {
    let userId: String
    let teamName: String
    let accessToken: String
}

final class SlackManager: NSObject {

    // ┌──────────────────────────────────────────────────────┐
    // │  REPLACE with your Slack App credentials              │
    // └──────────────────────────────────────────────────────┘
    private let clientID = "10477916588257.10464995370402"
    private let clientSecret = "REPLACE_WITH_ACTUAL_SLACK_CLIENT_SECRET"
    
    // Use https redirect — Slack requires HTTPS.
    // Option A: Host a tiny redirect page that bounces to ledger://slack/callback
    // Option B: Use any HTTPS URL you own (the code comes as a query param)
    // For development, we use ASWebAuthenticationSession's callbackURLScheme
    // which intercepts the redirect locally — but we still need an HTTPS URL
    // registered with Slack. Use a simple static page or https://localhost.
    //
    // SETUP: In Slack App → OAuth & Permissions → Redirect URLs, add:
    //   https://YOUR_GITHUB_USERNAME.github.io/ledger/callback
    // Then create that GitHub Pages repo with a simple redirect page (see below).
    //
    // OR for quick dev: use https://httpbin.org/anything as the redirect URL.
    private let redirectURI = "https://httpbin.org/anything"

        private let slackBaseURL = "https://slack.com/api"

        private var userToken: String?
        private var botToken: String?
        private var currentUserId: String?

        // ASWebAuthenticationSession for OAuth
        private var authSession: ASWebAuthenticationSession?

        // MARK: - OAuth Sign In

        @MainActor
        func signIn() async throws -> SlackSignInResult {
            let scopes = "channels:history,channels:read,groups:history,groups:read,im:history,im:read,mpim:history,mpim:read,chat:write,users:read"
            let encodedRedirect = redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI
            let authURL = "https://slack.com/oauth/v2/authorize?client_id=\(clientID)&user_scope=\(scopes)&redirect_uri=\(encodedRedirect)"

            guard let url = URL(string: authURL) else {
                throw SlackError.invalidURL
            }

            // ASWebAuthenticationSession intercepts the redirect before the browser follows it.
            // For HTTPS redirects, use "https" as the callbackURLScheme.
            let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "https") { callbackURL, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let callbackURL = callbackURL,
                          let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "code" })?.value else {
                        continuation.resume(throwing: SlackError.noAuthCode)
                        return
                    }
                    continuation.resume(returning: code)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.authSession = session
                session.start()
            }

            // Exchange code for token
            let tokenURL = "\(slackBaseURL)/oauth.v2.access"
            var request = URLRequest(url: URL(string: tokenURL)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "client_id=\(clientID)&client_secret=\(clientSecret)&code=\(code)&redirect_uri=\(encodedRedirect)"
            request.httpBody = body.data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            print("🔄 Slack token response: ok=\(json["ok"] ?? "nil")")

            guard let authedUser = json["authed_user"] as? [String: Any],
                  let token = authedUser["access_token"] as? String,
                  let userId = authedUser["id"] as? String else {
                let slackError = json["error"] as? String ?? "unknown"
                print("❌ Slack token exchange failed: \(slackError)")
                throw SlackError.tokenExchangeFailed
            }

            self.userToken = token
            self.currentUserId = userId

            let teamName = (json["team"] as? [String: Any])?["name"] as? String ?? "Slack"

            return SlackSignInResult(
                userId: userId,
                teamName: teamName,
                accessToken: token
            )
        }

        func signOut() {
            userToken = nil
            botToken = nil
            currentUserId = nil
        }

        // MARK: - Fetch Recent DMs & Mentions

        func fetchRecentMessages(accessToken: String, since sinceOverride: Date? = nil, maxChannels: Int = 20) async throws -> [LedgerEmail] {
            var allMessages: [LedgerEmail] = []

            // Step 1: Get DM channels (im = direct messages)
            let convURL = "\(slackBaseURL)/conversations.list?types=im,mpim&limit=\(maxChannels)"
            let convData = try await authenticatedGET(url: convURL, token: accessToken)
            let convJson = try JSONSerialization.jsonObject(with: convData) as? [String: Any] ?? [:]
            let channels = convJson["channels"] as? [[String: Any]] ?? []

            let since = sinceOverride ?? Date.sinceLastWindow
            let oldest = String(since.timeIntervalSince1970)

            // Step 2: For each DM channel, fetch recent messages
            for channel in channels.prefix(15) {
                guard let channelId = channel["id"] as? String else { continue }

                let histURL = "\(slackBaseURL)/conversations.history?channel=\(channelId)&oldest=\(oldest)&limit=10"
                let histData = try await authenticatedGET(url: histURL, token: accessToken)
                let histJson = try JSONSerialization.jsonObject(with: histData) as? [String: Any] ?? [:]
                let messages = histJson["messages"] as? [[String: Any]] ?? []

                for msg in messages {
                    guard let userId = msg["user"] as? String,
                          userId != currentUserId,   // Skip own messages
                          let text = msg["text"] as? String,
                          let ts = msg["ts"] as? String else { continue }

                    // Skip bot messages
                    if msg["bot_id"] != nil { continue }

                    let senderName = await fetchUserName(userId: userId, token: accessToken)
                    let date = Date(timeIntervalSince1970: Double(ts) ?? Date().timeIntervalSince1970)

                    let item = LedgerEmail(
                        id: "\(channelId)_\(ts)",
                        source: .slack,
                        threadId: channelId,
                        messageId: ts,
                        senderName: senderName,
                        senderEmail: userId,  // Store Slack user ID here
                        subject: "",
                        snippet: String(text.prefix(100)),
                        body: text,
                        date: date,
                        isUnread: true
                    )
                    allMessages.append(item)
                }
            }

            return allMessages
        }

        // MARK: - Send Reply

        func sendReply(
            accessToken: String,
            channelId: String,
            threadTs: String?,
            text: String
        ) async throws {
            let url = "\(slackBaseURL)/chat.postMessage"
            var payload: [String: Any] = [
                "channel": channelId,
                "text": text
            ]
            if let ts = threadTs {
                payload["thread_ts"] = ts  // Reply in thread
            }

            let jsonData = try JSONSerialization.data(withJSONObject: payload)

            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            guard json["ok"] as? Bool == true else {
                throw SlackError.sendFailed
            }
        }

        // MARK: - User Name Cache

        private var userNameCache: [String: String] = [:]

        private func fetchUserName(userId: String, token: String) async -> String {
            if let cached = userNameCache[userId] { return cached }

            let url = "\(slackBaseURL)/users.info?user=\(userId)"
            do {
                let data = try await authenticatedGET(url: url, token: token)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let user = json["user"] as? [String: Any] ?? [:]
                let profile = user["profile"] as? [String: Any] ?? [:]
                let name = profile["real_name"] as? String
                    ?? profile["display_name"] as? String
                    ?? user["name"] as? String
                    ?? "Unknown"
                userNameCache[userId] = name
                return name
            } catch {
                return "Unknown"
            }
        }

        // MARK: - Helpers

        private func authenticatedGET(url: String, token: String) async throws -> Data {
            guard let requestURL = URL(string: url) else { throw SlackError.invalidURL }
            var request = URLRequest(url: requestURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SlackError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return data
        }
    }

    // MARK: - ASWebAuthenticationSession Presentation

    extension SlackManager: ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first else {
                return ASPresentationAnchor()
            }
            return window
        }
    }

    // MARK: - Errors

    enum SlackError: LocalizedError {
        case invalidURL
        case noAuthCode
        case tokenExchangeFailed
        case apiError(statusCode: Int)
        case sendFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .noAuthCode: return "No authorization code received"
            case .tokenExchangeFailed: return "Token exchange failed"
            case .apiError(let c): return "Slack API error \(c)"
            case .sendFailed: return "Failed to send message"
            }
        }
    }
