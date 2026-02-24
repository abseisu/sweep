// RelayAPI.swift
// HTTP client for the Ledger backend — pairing, message push, reply polling.

import Foundation

struct PairResult {
    let jwt: String
    let userId: String
}

struct PendingReply: Decodable {
    let id: String
    let recipient: String
    let text: String
}

final class RelayAPI {
    private let baseURL = "https://ledger-api-adnanbseisu.fly.dev"

    // MARK: - Pairing

    func confirmPairing(code: String) async throws -> PairResult {
        struct PairRequest: Encodable { let code: String; let macName: String }
        struct PairResponse: Decodable { let jwt: String; let userId: String }

        let macName = Host.current().localizedName ?? "Mac"
        let body = PairRequest(code: code, macName: macName)
        let result: PairResponse = try await post("/imessage/pair/confirm", body: body)
        return PairResult(jwt: result.jwt, userId: result.userId)
    }

    // MARK: - Push Messages

    func pushMessages(_ messages: [ChatMessage], lastReplyDates: [String: Date] = [:], jwt: String) async throws {
        struct PushRequest: Encodable {
            let messages: [MessagePayload]
            let context: [String: [ContextMessage]]
            let lastReplyDates: [String: String]
            let groupMembers: [String: [String]]  // chatId → array of phone numbers
        }
        struct MessagePayload: Encodable {
            let id: String
            let senderName: String
            let senderPhone: String
            let text: String
            let date: String
            let chatId: String
            let isGroupChat: Bool
            let groupName: String?
            let isFromMe: Bool
        }
        struct ContextMessage: Encodable {
            let text: String
            let isFromMe: Bool
            let date: String
            let senderName: String?
        }
        struct OK: Decodable { let ok: Bool }

        let formatter = ISO8601DateFormatter()
        let payload = PushRequest(
            messages: messages.map { msg in
                MessagePayload(
                    id: msg.id,
                    senderName: msg.senderName,
                    senderPhone: msg.senderPhone,
                    text: msg.text,
                    date: formatter.string(from: msg.date),
                    chatId: msg.chatId,
                    isGroupChat: msg.isGroupChat,
                    groupName: msg.groupName,
                    isFromMe: msg.isFromMe
                )
            },
            context: messages.reduce(into: [String: [ContextMessage]]()) { dict, msg in
                if dict[msg.chatId] == nil, let ctx = msg.conversationContext {
                    dict[msg.chatId] = ctx.map { c in
                        ContextMessage(
                            text: c.text,
                            isFromMe: c.isFromMe,
                            date: formatter.string(from: c.date),
                            senderName: c.senderName
                        )
                    }
                }
            },
            lastReplyDates: lastReplyDates.reduce(into: [:]) { dict, pair in
                dict[pair.key] = formatter.string(from: pair.value)
            },
            groupMembers: messages.reduce(into: [String: [String]]()) { dict, msg in
                if msg.isGroupChat, dict[msg.chatId] == nil, let members = msg.groupMembers {
                    dict[msg.chatId] = members
                }
            }
        )

        let _: OK = try await post("/imessage/messages", body: payload, jwt: jwt)
    }

    // MARK: - Pending Replies

    func getPendingReplies(jwt: String) async throws -> [PendingReply] {
        struct ReplyResponse: Decodable { let replies: [PendingReply] }
        let result: ReplyResponse = try await get("/imessage/replies", jwt: jwt)
        return result.replies
    }

    func ackReply(id: String, jwt: String) async throws {
        struct AckRequest: Encodable { let id: String }
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await post("/imessage/reply/ack", body: AckRequest(id: id), jwt: jwt)
    }

    // MARK: - Verify Active Items

    /// Sends lastReplyDates for all known chats so the backend can dismiss
    /// items the user has already replied to (e.g. while Mac was off).
    func verifyActive(lastReplyDates: [String: Date], jwt: String) async throws -> Int {
        struct VerifyRequest: Encodable { let lastReplyDates: [String: String] }
        struct VerifyResponse: Decodable { let ok: Bool; let dismissed: Int }

        let formatter = ISO8601DateFormatter()
        let payload = VerifyRequest(
            lastReplyDates: lastReplyDates.reduce(into: [:]) { dict, pair in
                dict[pair.key] = formatter.string(from: pair.value)
            }
        )
        let result: VerifyResponse = try await post("/imessage/verify-active", body: payload, jwt: jwt)
        return result.dismissed
    }

    // MARK: - Disconnect

    func disconnect(jwt: String) async throws {
        struct Empty: Encodable {}
        struct OK: Decodable { let ok: Bool }
        let _: OK = try await post("/imessage/disconnect", body: Empty(), jwt: jwt)
    }

    // MARK: - Re-Auth (when iOS user changed)

    struct ReauthResult: Decodable {
        let jwt: String
        let userId: String
        let expiresAt: String
    }

    /// Re-authenticate by sending the expired JWT as a Bearer token.
    /// The backend verifies the signature (ignoring expiry) to prove prior auth.
    func reauth(expiredJwt: String) async throws -> ReauthResult {
        struct Empty: Encodable {}
        return try await post("/imessage/reauth", body: Empty(), jwt: expiredJwt)
    }

    // MARK: - HTTP Helpers

    private func get<T: Decodable>(_ path: String, jwt: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if let jwt = jwt {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RelayAPIError.httpError(code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: Encodable, jwt: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        if let jwt = jwt {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RelayAPIError.httpError(code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum RelayAPIError: LocalizedError {
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server error (\(code))"
        }
    }
}


