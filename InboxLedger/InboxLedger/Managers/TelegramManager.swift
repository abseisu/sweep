// TelegramManager.swift
// Ledger
//
// Telegram integration via Telegram Bot API.
//
// SETUP:
// 1. Message @BotFather on Telegram → /newbot → name it "Ledger Bot"
// 2. Copy the bot token (looks like: 123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11)
// 3. Paste it below
// 4. Users need to message the bot first (or add it to groups)
//    to establish a chat that the bot can read from.
//
// HOW IT WORKS:
// - The bot receives messages sent TO it (DMs) or in groups where it's added
// - /getUpdates polls for new messages
// - /sendMessage sends replies
// - This is a polling approach; for production, you'd use webhooks

import Foundation
import AuthenticationServices

struct TelegramSignInResult {
    let userId: String
    let displayName: String
    let botToken: String
}

final class TelegramManager: NSObject {

    // ┌──────────────────────────────────────────────────────┐
    // │  REPLACE with your Telegram Bot Token                 │
    // └──────────────────────────────────────────────────────┘
    private let botToken = "8478743122:AAERaX0zJaOwvbIqrgB5-LcIUQOLXlyVpn8"

    private var baseURL: String { "https://api.telegram.org/bot\(botToken)" }

    private var lastUpdateId: Int = 0

    // MARK: - Sign In (verify bot is alive + get bot info)

    func signIn() async throws -> TelegramSignInResult {
        let url = "\(baseURL)/getMe"
        let data = try await get(url: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard json["ok"] as? Bool == true,
              let result = json["result"] as? [String: Any] else {
            throw TelegramError.invalidBotToken
        }

        let botName = result["first_name"] as? String ?? "Ledger Bot"
        let botId = result["id"] as? Int ?? 0

        return TelegramSignInResult(
            userId: String(botId),
            displayName: botName,
            botToken: botToken
        )
    }

    func signOut() {
        lastUpdateId = 0
    }

    // MARK: - Fetch Recent Messages

    func fetchRecentMessages() async throws -> [LedgerEmail] {
        // Use getUpdates to poll for messages
        let url = "\(baseURL)/getUpdates?offset=\(lastUpdateId > 0 ? lastUpdateId + 1 : 0)&limit=50&allowed_updates=[\"message\"]"
        let data = try await get(url: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard json["ok"] as? Bool == true,
              let results = json["result"] as? [[String: Any]] else {
            return []
        }

        let since = Date.twentyFourHoursAgo
        var messages: [LedgerEmail] = []

        for update in results {
            guard let updateId = update["update_id"] as? Int else { continue }
            lastUpdateId = max(lastUpdateId, updateId)

            guard let message = update["message"] as? [String: Any],
                  let text = message["text"] as? String,
                  let from = message["from"] as? [String: Any],
                  let chat = message["chat"] as? [String: Any],
                  let dateEpoch = message["date"] as? Double else { continue }

            // Skip bot commands
            if text.hasPrefix("/") { continue }

            let date = Date(timeIntervalSince1970: dateEpoch)
            if date < since { continue }

            let fromId = from["id"] as? Int ?? 0
            let firstName = from["first_name"] as? String ?? ""
            let lastName = from["last_name"] as? String ?? ""
            let username = from["username"] as? String ?? ""
            let senderName = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)

            let chatId = chat["id"] as? Int ?? 0
            let chatTitle = chat["title"] as? String  // Group name, nil for DMs
            let messageId = message["message_id"] as? Int ?? 0

            let subject = chatTitle ?? ""  // Group name as subject, empty for DMs

            let item = LedgerEmail(
                id: "tg_\(chatId)_\(messageId)",
                source: .telegram,
                threadId: String(chatId),
                messageId: String(messageId),
                senderName: senderName.isEmpty ? username : senderName,
                senderEmail: username.isEmpty ? String(fromId) : "@\(username)",
                subject: subject,
                snippet: String(text.prefix(100)),
                body: text,
                date: date,
                isUnread: true
            )
            messages.append(item)
        }

        return messages
    }

    // MARK: - Send Reply

    func sendReply(
        chatId: String,
        replyToMessageId: String?,
        text: String
    ) async throws {
        let url = "\(baseURL)/sendMessage"

        var payload: [String: Any] = [
            "chat_id": chatId,
            "text": text
        ]
        if let replyId = replyToMessageId, let id = Int(replyId) {
            payload["reply_to_message_id"] = id
        }

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard json["ok"] as? Bool == true else {
            let desc = json["description"] as? String ?? "Unknown error"
            throw TelegramError.sendFailed(desc)
        }
    }

    // MARK: - Helpers

    private func get(url: String) async throws -> Data {
        guard let requestURL = URL(string: url) else { throw TelegramError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: requestURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TelegramError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

// MARK: - Errors

enum TelegramError: LocalizedError {
    case invalidURL
    case invalidBotToken
    case apiError(statusCode: Int)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidBotToken: return "Invalid bot token"
        case .apiError(let c): return "Telegram API error \(c)"
        case .sendFailed(let d): return "Send failed: \(d)"
        }
    }
}
