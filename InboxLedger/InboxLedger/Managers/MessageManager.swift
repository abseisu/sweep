// MessageManager.swift
// Ledger
//
// iMessage integration — send-only via the native Messages compose sheet.
// No special entitlements or permissions required.
//
// Apple does not provide a public API to read iMessages,
// so this source works as a quick-reply channel:
// the AI drafts a response and the user sends it via the compose sheet.

import UIKit
import SwiftUI
import MessageUI

final class MessageManager: NSObject {

    // MARK: - Availability

    static var canSendMessages: Bool {
        MFMessageComposeViewController.canSendText()
    }

    // MARK: - Fetch

    /// Fetches iMessages from the backend that were pushed by the Mac relay.
    func fetchRecentMessages() async throws -> [LedgerEmail] {
        struct RelayMessage: Decodable {
            let id: String
            let senderName: String
            let senderPhone: String
            let text: String
            let date: String
            let chatId: String
            let isGroupChat: Bool?
            let groupName: String?
            let isFromMe: Bool?
            let aiSummary: String?
            let suggestedDraft: String?
            let replyability: Int?
            let detectedTone: String?
            let category: String?
            let conversationContext: [RelayContextMessage]?
            let structuredMessages: [StructuredMessage]?
        }
        struct RelayContextMessage: Decodable {
            let text: String
            let isFromMe: Bool
            let date: String
            let senderName: String?
        }
        struct StructuredMessage: Decodable {
            let text: String
            let date: String
            let senderName: String?
        }
        struct MessagesResponse: Decodable {
            let messages: [RelayMessage]
        }

        let response: MessagesResponse = try await BackendManager.shared.request(
            "GET", path: "/imessage/messages"
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        // ── Group messages by chatId so we produce exactly ONE card per conversation ──
        var chatGroups: [String: [RelayMessage]] = [:]
        for msg in response.messages {
            chatGroups[msg.chatId, default: []].append(msg)
        }

        return chatGroups.values.compactMap { group -> LedgerEmail? in
            // Sort messages in this chat newest-first so we can inspect the latest
            let sorted = group.sorted { lhs, rhs in
                let lDate = formatter.date(from: lhs.date)
                    ?? fallbackFormatter.date(from: lhs.date) ?? Date.distantPast
                let rDate = formatter.date(from: rhs.date)
                    ?? fallbackFormatter.date(from: rhs.date) ?? Date.distantPast
                return lDate > rDate
            }

            // Use the newest message as the representative for this chat
            let newest = sorted[0]

            // ── Determine if the conversation's latest messages are from the user ──
            // Check conversationContext first (full chat history from backend)
            if let ctx = newest.conversationContext, !ctx.isEmpty {
                // The last entry in conversationContext is the most recent message
                if ctx.last?.isFromMe == true {
                    // User was the last to respond — no card needed
                    return nil
                }
            } else {
                // No conversationContext — fall back to the message-level isFromMe flag.
                // If the newest message in this chat is from the user, skip.
                if newest.isFromMe == true { return nil }
            }

            // Also skip if EVERY message in the group is from the user
            if sorted.allSatisfy({ $0.isFromMe == true }) { return nil }

            let date = formatter.date(from: newest.date)
                ?? fallbackFormatter.date(from: newest.date)
                ?? Date()

            // Serialize conversation context as JSON for the card's scroll history
            var conversationContextJSON: String? = nil
            if let ctx = newest.conversationContext, !ctx.isEmpty {
                let ctxDicts: [[String: Any]] = ctx.map { c in
                    var d: [String: Any] = [
                        "text": c.text,
                        "isFromMe": c.isFromMe,
                    ]
                    if let name = c.senderName { d["senderName"] = name }
                    return d
                }
                if let data = try? JSONSerialization.data(withJSONObject: ctxDicts),
                   let str = String(data: data, encoding: .utf8) {
                    conversationContextJSON = str
                }
            }

            // ── Build snippet: only show the latest consecutive sender messages ──
            // (i.e. everything after the user's last reply)
            let snippetText: String
            if let structured = newest.structuredMessages, !structured.isEmpty {
                // Use conversationContext to find the date of the user's last reply
                var lastUserReplyDate: Date? = nil
                if let ctx = newest.conversationContext {
                    for c in ctx.reversed() {
                        if c.isFromMe {
                            lastUserReplyDate = formatter.date(from: c.date)
                                ?? fallbackFormatter.date(from: c.date)
                            break
                        }
                    }
                }

                // Filter structured messages to only those AFTER the user's last reply
                let relevantStructured: [StructuredMessage]
                if let cutoff = lastUserReplyDate {
                    relevantStructured = structured.filter { m in
                        let mDate = formatter.date(from: m.date)
                            ?? fallbackFormatter.date(from: m.date)
                            ?? Date.distantPast
                        return mDate > cutoff
                    }
                } else {
                    relevantStructured = structured
                }

                let toEncode = relevantStructured.isEmpty ? structured : relevantStructured
                let structDicts: [[String: Any]] = toEncode.map { m in
                    var d: [String: Any] = [
                        "text": m.text,
                        "date": m.date,
                    ]
                    if let name = m.senderName { d["senderName"] = name }
                    return d
                }
                if let data = try? JSONSerialization.data(withJSONObject: structDicts),
                   let str = String(data: data, encoding: .utf8) {
                    snippetText = str
                } else {
                    snippetText = toEncode.map { $0.text }.joined(separator: "\n")
                }
            } else {
                snippetText = String(newest.text.prefix(100))
            }

            let body = newest.text

            var item = LedgerEmail(
                id: newest.id,
                source: .imessage,
                threadId: newest.chatId,
                messageId: "",
                senderName: newest.isGroupChat == true ? (newest.groupName ?? newest.senderName) : newest.senderName,
                senderEmail: newest.senderPhone,
                subject: "",
                snippet: snippetText,
                body: body,
                date: date,
                isUnread: true,
                accountId: "imessage",
                aiSummary: newest.aiSummary,
                suggestedDraft: newest.suggestedDraft,
                replyability: newest.replyability ?? 60
            )
            item.detectedTone = newest.detectedTone
            item.category = newest.category
            item.conversationContext = conversationContextJSON
            return item
        }
    }
}

// MARK: - SwiftUI Bridge for Message Compose

struct MessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    var onDismiss: () -> Void
    var onResult: ((MessageComposeResult) -> Void)? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<MessageComposeView>) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [recipient]
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: UIViewControllerRepresentableContext<MessageComposeView>) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss, onResult: onResult)
    }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onDismiss: () -> Void
        let onResult: ((MessageComposeResult) -> Void)?

        init(onDismiss: @escaping () -> Void, onResult: ((MessageComposeResult) -> Void)?) {
            self.onDismiss = onDismiss
            self.onResult = onResult
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
            if let onResult {
                onResult(result)
            } else {
                onDismiss()
            }
        }
    }
}

// MARK: - Errors

enum MessageError: LocalizedError {
    case cannotSendMessages

    var errorDescription: String? {
        switch self {
        case .cannotSendMessages:
            return "This device cannot send text messages."
        }
    }
}
