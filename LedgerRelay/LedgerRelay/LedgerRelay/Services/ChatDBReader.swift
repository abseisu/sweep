// ChatDBReader.swift
// Reads iMessages from ~/Library/Messages/chat.db (SQLite).
// Requires Full Disk Access permission.

import Foundation
import SQLite3

struct ChatMessage {
    let id: String              // Unique: ROWID from message table
    let senderName: String      // Contact name or phone number
    let senderPhone: String     // Phone number or email (iMessage handle)
    let text: String
    let date: Date
    let isFromMe: Bool
    let chatId: String          // chat_identifier (phone/email of the conversation)
    let isGroupChat: Bool
    let groupName: String?
    var conversationContext: [ContextMessage]?  // Recent messages from both sides
    var groupMembers: [String]?  // Phone numbers/emails of group chat participants
}

struct ContextMessage {
    let text: String
    let isFromMe: Bool
    let date: Date
    let senderName: String?
}

final class ChatDBReader {
    private let dbPath: String
    private var db: OpaquePointer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbPath = (home as NSString).appendingPathComponent("Library/Messages/chat.db")
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Open DB

    private func openDB() throws {
        guard db == nil else { return }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(dbPath, &db, flags, nil)
        if result != SQLITE_OK {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            db = nil
            throw ChatDBError.cannotOpen(errorMsg)
        }
    }

    // MARK: - Fetch New Messages

    func fetchNewMessages(since: Date, limit: Int = 50) throws -> [ChatMessage] {
        try openDB()
        guard let db = db else { throw ChatDBError.notOpen }

        let appleEpochOffset: TimeInterval = 978307200
        let sinceApple = since.timeIntervalSince1970 - appleEpochOffset
        let sinceValue = sinceApple * 1_000_000_000

        let query = """
            SELECT
                m.ROWID,
                m.text,
                m.date,
                m.is_from_me,
                m.handle_id,
                h.id AS handle,
                c.chat_identifier,
                c.display_name,
                c.style
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.date > ?
              AND m.text IS NOT NULL
              AND m.text != ''
              AND m.associated_message_type NOT IN (2000,2001,2002,2003,2004,2005,3000,3001,3002,3003,3004,3005)
            ORDER BY m.date DESC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw ChatDBError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(sinceValue))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var messages: [ChatMessage] = []
        var chatIds = Set<String>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let text = columnText(stmt, 1) ?? ""
            let dateValue = sqlite3_column_int64(stmt, 2)
            let isFromMe = sqlite3_column_int(stmt, 3) == 1
            let handle = columnText(stmt, 4) ?? ""
            let handleId = columnText(stmt, 5) ?? handle
            let chatIdentifier = columnText(stmt, 6) ?? handleId
            let displayName = columnText(stmt, 7)
            let chatStyle = sqlite3_column_int(stmt, 8)

            let dateSeconds = Double(dateValue) / 1_000_000_000
            let date = Date(timeIntervalSince1970: dateSeconds + appleEpochOffset)
            let finalDate: Date
            if date.timeIntervalSince1970 < 1577836800 || date.timeIntervalSince1970 > 1893456000 {
                finalDate = Date(timeIntervalSince1970: Double(dateValue) + appleEpochOffset)
            } else {
                finalDate = date
            }

            guard !text.isEmpty else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isReactionText(trimmed) { continue }

            let isGroup = chatStyle == 43
            let senderName = isFromMe ? "Me" : (displayName ?? formatPhoneNumber(handleId))

            chatIds.insert(chatIdentifier)

            messages.append(ChatMessage(
                id: "imsg_\(rowId)",
                senderName: senderName,
                senderPhone: handleId,
                text: text,
                date: finalDate,
                isFromMe: isFromMe,
                chatId: chatIdentifier,
                isGroupChat: isGroup,
                groupName: isGroup ? displayName : nil,
                conversationContext: nil
            ))
        }

        // Fetch conversation context for each chat
        for chatId in chatIds {
            if let context = try? fetchConversationContext(chatId: chatId, before: Date(), limit: 50) {
                if let idx = messages.firstIndex(where: { $0.chatId == chatId }) {
                    messages[idx].conversationContext = context
                }
            }
        }

        // Fetch group members for group chats
        for i in messages.indices {
            if messages[i].isGroupChat {
                messages[i].groupMembers = try? fetchGroupMembers(chatId: messages[i].chatId)
            }
        }

        return messages
    }

    // MARK: - Group Members

    /// Fetches all participant phone numbers/emails for a group chat.
    func fetchGroupMembers(chatId: String) throws -> [String] {
        try openDB()
        guard let db = db else { throw ChatDBError.notOpen }

        let query = """
            SELECT h.id
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            JOIN chat c ON chj.chat_id = c.ROWID
            WHERE c.chat_identifier = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (chatId as NSString).utf8String, -1, nil)

        var members: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let handle = columnText(stmt, 0) {
                members.append(handle)
            }
        }

        return members
    }

    // MARK: - Conversation Context

    /// Fetches the last N messages from BOTH sides of a conversation.
    /// Dead simple: get the most recent 50 messages, both incoming and outgoing.
    /// Returns chronologically ordered (oldest first).
    func fetchConversationContext(chatId: String, before: Date, limit: Int = 50) throws -> [ContextMessage] {
        try openDB()
        guard let db = db else { throw ChatDBError.notOpen }

        let appleEpochOffset: TimeInterval = 978307200
        let beforeApple = before.timeIntervalSince1970 - appleEpochOffset
        let beforeValue = Int64(beforeApple * 1_000_000_000)

        let query = """
            SELECT
                m.text,
                m.is_from_me,
                m.date,
                h.id AS handle,
                c.display_name
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE c.chat_identifier = ?1
              AND m.date < ?2
              AND m.text IS NOT NULL
              AND m.text != ''
              AND m.associated_message_type NOT IN (2000,2001,2002,2003,2004,2005,3000,3001,3002,3003,3004,3005)
            ORDER BY m.date DESC
            LIMIT ?3
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            print("📨 Context query failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (chatId as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, beforeValue)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var context: [ContextMessage] = []
        var fromMeCount = 0
        var fromThemCount = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = columnText(stmt, 0) ?? ""
            let isFromMe = sqlite3_column_int(stmt, 1) == 1
            let dateValue = sqlite3_column_int64(stmt, 2)
            let handleId = columnText(stmt, 3)
            let displayName = columnText(stmt, 4)

            let dateSeconds = Double(dateValue) / 1_000_000_000
            var date = Date(timeIntervalSince1970: dateSeconds + appleEpochOffset)
            if date.timeIntervalSince1970 < 1577836800 || date.timeIntervalSince1970 > 1893456000 {
                date = Date(timeIntervalSince1970: Double(dateValue) + appleEpochOffset)
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isReactionText(trimmed) { continue }

            if isFromMe { fromMeCount += 1 } else { fromThemCount += 1 }

            let senderName = isFromMe ? nil : (displayName ?? (handleId.map { formatPhoneNumber($0) }))

            context.append(ContextMessage(
                text: text,
                isFromMe: isFromMe,
                date: date,
                senderName: senderName
            ))
        }

        print("📨 Context for \(chatId.prefix(20)): \(context.count) msgs (\(fromMeCount) fromMe, \(fromThemCount) fromThem)")

        // Return in chronological order (oldest first)
        return context.reversed()
    }

    // MARK: - Chat Discovery

    /// Returns chat identifiers for all conversations with recent activity.
    /// Used by verify-active to check if the user replied to any active cards.
    func allRecentChatIds(limit: Int = 50) throws -> Set<String> {
        try openDB()
        guard let db = db else { throw ChatDBError.notOpen }

        let query = """
            SELECT DISTINCT c.chat_identifier
            FROM chat c
            JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
            JOIN message m ON cmj.message_id = m.ROWID
            WHERE m.date > ?
              AND c.chat_identifier IS NOT NULL
            ORDER BY m.date DESC
            LIMIT ?
        """

        let appleEpochOffset: TimeInterval = 978307200
        // Look back 7 days
        let sinceApple = (Date().timeIntervalSince1970 - 7 * 86400) - appleEpochOffset
        let sinceValue = Int64(sinceApple * 1_000_000_000)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sinceValue)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var chatIds = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = columnText(stmt, 0) {
                chatIds.insert(id)
            }
        }

        return chatIds
    }

    // MARK: - Last Reply Tracking

    /// For each chatId, finds the date of the user's most recent outgoing message.
    func lastReplyDates(for chatIds: Set<String>) throws -> [String: Date] {
        try openDB()
        guard let db = db else { throw ChatDBError.notOpen }

        let appleEpochOffset: TimeInterval = 978307200
        var results: [String: Date] = [:]

        for chatId in chatIds {
            let query = """
                SELECT MAX(m.date)
                FROM message m
                LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
                LEFT JOIN chat c ON cmj.chat_id = c.ROWID
                WHERE c.chat_identifier = ?
                  AND m.is_from_me = 1
                  AND m.text IS NOT NULL
                  AND m.text != ''
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (chatId as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                let dateValue = sqlite3_column_int64(stmt, 0)
                if dateValue > 0 {
                    let dateSeconds = Double(dateValue) / 1_000_000_000
                    var date = Date(timeIntervalSince1970: dateSeconds + appleEpochOffset)
                    if date.timeIntervalSince1970 < 1577836800 || date.timeIntervalSince1970 > 1893456000 {
                        date = Date(timeIntervalSince1970: Double(dateValue) + appleEpochOffset)
                    }
                    results[chatId] = date
                }
            }
        }

        return results
    }

    // MARK: - Helpers

    private func isReactionText(_ text: String) -> Bool {
        let prefixes = [
            "Loved \u{201c}", "Liked \u{201c}", "Disliked \u{201c}",
            "Laughed at \u{201c}", "Emphasized \u{201c}", "Questioned \u{201c}",
            "Loved an image", "Liked an image", "Disliked an image",
            "Laughed at an image", "Emphasized an image", "Questioned an image",
            "Loved a sticker", "Liked a sticker",
            "Removed a heart from", "Removed a like from",
            "Removed a dislike from", "Removed a laugh from",
            "Removed an exclamation from", "Removed a question mark from",
        ]
        return prefixes.contains(where: { text.hasPrefix($0) })
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func formatPhoneNumber(_ handle: String) -> String {
        if handle.contains("@") { return handle }
        let digits = handle.filter { $0.isNumber }
        if digits.count == 10 {
            let area = digits.prefix(3)
            let mid = digits.dropFirst(3).prefix(3)
            let last = digits.suffix(4)
            return "(\(area)) \(mid)-\(last)"
        }
        return handle
    }
}

// MARK: - Errors

enum ChatDBError: LocalizedError {
    case cannotOpen(String)
    case notOpen
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let msg): return "Cannot open chat.db: \(msg)"
        case .notOpen: return "Database not open"
        case .queryFailed(let msg): return "Query failed: \(msg)"
        }
    }
}

